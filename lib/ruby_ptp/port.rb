require 'socket'
require 'inline'
require 'ipaddr'
require 'thread'
require 'bigdecimal'
require 'logger'

module RubyPtp

  class Port
    attr_reader :state, :ipaddr, :ts_mode, :slave_state, :timestamps,
      :savestamps, :activestamps, :delay, :phase_error, :freq_error

    PTP_MULTICAST_ADDR = "224.0.1.129"
    EVENT_PORT         = 319
    GENERAL_PORT       = 320
    SIOCSHWTSTAMP      = 0x89b0
    TAI_OFFSET         = 0 # TAI is 36 seconds in front of UTC

    STATES = {INITIALIZING: 0x01,
              FAULTY:       0x02,
              DISABLED:     0x03,
              LISTENING:    0x04,
              PRE_MASTER:   0x05,
              MASTER:       0x06,
              PASSIVE:      0x07,
              UNCALIBRATED: 0x08,
              SLAVE:        0x09}


    def initialize options = {}
      # Create a logger and set log level
      @log = Logger.new $stdout
      @log.progname = "RubyPTP"
      @log.level = options[:loglevel] || Logger::INFO

      # Get IP and MAC of interface
      @ipaddr = getIP(options[:interface])
      @hwaddr = getMAC(options[:interface])

      # Do padding of MAC to create port identity and revert it to a 64-bit int
      @portIdentity = @hwaddr.split(":").map!{|a| a.to_i(16)}
        .insert(3, 0xff, 0xff, 0xff).pack("C*").unpack("Q>").first

      # Set up initial states
      @state = STATES[:INITIALIZING]
      @slave_state = :WAIT_FOR_SYNC
      @sequenceId = 1

      # Set mode of timestamps
      @ts_mode = options[:ts_mode]

      # Ready object for saving timestamps
      @savestamps    = options[:savestamps] || 3
      @timestamps    = [].fill(nil, 0, @savestamps)
      @delay         = []
      @phase_error   = []
      @freq_error    = []
      @sync_id       = -1
      @activestamps  = [].fill(nil, 0, 4)

      # Create event socket
      @event_socket = setupEventSocket(options[:interface])

      # Generate socket for general messages
      @general_socket = UDPSocket.new
      @general_socket.setsockopt(:SOCKET,
                             Socket::IP_MULTICAST_IF, IPAddr.new(@ipaddr).hton)
      ip = IPAddr.new(PTP_MULTICAST_ADDR).hton + IPAddr.new("0.0.0.0").hton
      @general_socket.setsockopt(Socket::IPPROTO_IP,
                                 Socket::IP_ADD_MEMBERSHIP, ip)
      @general_socket.bind(Socket::INADDR_ANY, GENERAL_PORT)

      # Clear settings on clock
      ChangeTime.new.clear()

      # We are only running in slave mode
      @state = STATES[:SLAVE]
    end

    def startPtp options = {}
      Thread.abort_on_exception = true
      @log.debug "Starting general thread"
      general = Thread.new do
        while @state == STATES[:SLAVE] do
          msg, addr, rflags, *cfg = @general_socket.recvmsg
          parseGeneral(msg, addr, rflags, cfg)
        end
        @general_socket.close
      end

      @log.debug "Starting event thread"
      event = Thread.new do
        while @state == STATES[:SLAVE] do
          msg, addr, rflags, *cfg = @event_socket.recvmsg

          # TODO:Right now we'll just use SW TS to get things going and then do
          # something smarter when to protocol is working
          #sw_ts = Time.now.utc
          sw_ts = clock_gettime
          parseEvent(msg, addr, rflags, cfg, [sw_ts[0] + TAI_OFFSET, sw_ts[1]])
        end
        @event_socket.close
      end

      Signal.trap("INT") { 
        @state = STATES[:DISABLED]
        i=0
        @delay.each do |d|
          print "(#{i},#{d.to_f})"
          i += 1
        end
      }

      general.join
      event.join
    end

    private


    # Either setup socket in HW or SW timestamping mode
    def setupEventSocket(interface)
      socket = UDPSocket.new
      ip = IPAddr.new(PTP_MULTICAST_ADDR).hton + IPAddr.new("0.0.0.0").hton
      socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, ip)

      # If we are trying to do HW stamps, we need to initialise the network
      # interface to actually make the timestamps.
      if @ts_mode == :TIMESTAMPHW

        # Construct the command for the network interface in a slightly crude
        # way according to:
        # https://www.kernel.org/doc/Documentation/networking/timestamping.txt
        hwstamp_config = [0,1,5].pack("iii")
        ifreq = interface.ljust(16,"\x00") + [hwstamp_config].pack("P")
        # Make sure things worked
        if socket.ioctl(SIOCSHWTSTAMP, ifreq) != 0
          @log.error "Unable to initialise HW stamping"
        end
        socket.setsockopt(:SOCKET, Socket::SO_TIMESTAMPING, 69)
      end

      # Enable the software timestamps for comparison
      socket.setsockopt(:SOCKET, :TIMESTAMPNS, true)
      socket.bind(Socket::INADDR_ANY, EVENT_PORT)

      return socket
    end

    def getMessage(msg)
      Message.new(parse: msg)
    end

    def parseEvent(msg, addr, rflags, cfg, ts)
      message = getMessage(msg)
      @log.debug message.inspect

      hw_ts, sw_ts = getTimestamps(cfg)

      # Figure out what to do with the packages
      case message.type

      # In case of a SYNC
      when Message::SYNC
        if @slave_state == :WAIT_FOR_SYNC
          if message.originTimestamp == -1

            # In case the follow_up arrives first we need to deal with changing
            # the order in which we are working. When the sequence ID is
            # already up to date, we'll go straight to delay_req as we should
            # already have t1 recorded somewhere.
            recordTimestamps(t2: timeArrToBigDec(*ts))
            if @sync_id < message.sequenceId
              @slave_state = :WAIT_FOR_FOLLOW_UP
            elsif @sync_id == message.sequenceId
              t3 = sendDelayReq()
              recordTimestamps(t3: timeArrToBigDec(*t3))
              @slave_state = :WAIT_FOR_DELAY_RESP
            else
              @log.warn("SYNC sequence ID is smaller than last one..")
            end
            @sync_id = message.sequenceId

          else
            t1 = timeArrToBigDec(*message.originTimestamp)
            t2 = timeArrToBigDec(*ts)
            recordTimestamps(t1: t1, t2: t2)
            t3 = sendDelayReq()
            recordTimestamps(t3: timeArrToBigDec(*t3))
            @slave_state = :WAIT_FOR_DELAY_RESP
          end
        end
      end

      @log.debug @slave_state
    end

    def parseGeneral(msg, addr, rflags, cfg)
      message = getMessage(msg)
      @log.debug message.inspect

      case message.type
      when Message::ANNOUNCE
        # bob...

      # In case of a FOLLOW_UP
      when Message::FOLLOW_UP
        if @slave_state == :WAIT_FOR_FOLLOW_UP || @sync_id < message.sequenceId
          recordTimestamps(t1: timeArrToBigDec(*message.originTimestamp))
          @slave_state = :WAIT_FOR_SYNC
          unless @sync_id < message.sequenceId
            t3 = sendDelayReq()
            recordTimestamps(t3: timeArrToBigDec(*t3))
            @slave_state = :WAIT_FOR_DELAY_RESP
          end
        end
      # In case of a DELAY_RESP
      when Message::DELAY_RESP
        if @slave_state == :WAIT_FOR_DELAY_RESP
          recordTimestamps(t4: timeArrToBigDec(*message.receiveTimestamp))
          updateTime()
          @slave_state = :WAIT_FOR_SYNC
        end
      end

      @log.debug @slave_state
    end

    # Update whatever timestamps are being thrown at us
    def recordTimestamps(t1: nil, t2: nil, t3: nil, t4: nil)
      @activestamps[0] = t1 if t1
      @activestamps[1] = t2 if t2
      @activestamps[2] = t3 if t3
      @activestamps[3] = t4 if t4
    end

    # Do some actual calculations on the time updating and bookeeping of
    # timestamp variables.
    def updateTime

      # Cleanup phase
      @timestamps.shift
      @timestamps << @activestamps

      t1, t2, t3, t4 = @activestamps
      @log.debug "t1: #{t1.to_f}, "\
       "t2: #{t2.to_f}, "\
       "t3: #{t3.to_f}, "\
       "t4: #{t4.to_f}"

      # Calculate link delay
      @delay << ((t2 - t1) + (t4 - t3)) / 2
      # Calculate phase error
      @phase_error << ((t2 - t1) - (t4 - t3)) / 2

      # Calculate frequency error
      if @timestamps[-2]
        old = @timestamps[-2]
        old_delay = @delay[-2]
        @freq_error << ((@activestamps[0] - old[0]) / (
                       (@activestamps[1] + delay.last) -
                      (old[1] + old_delay)))
      end

      # TODO: Update system
      @log.info "Delay: #{@delay.last.to_f}, " \
        "phase_err: #{@phase_error.last.to_f}, "\
        "freq_err: #{@freq_error.last.to_f if @freq_error}"

      # Adjust phase
      sign = @phase_error.last.to_f < 0 ? -1 : 1
      parts = @phase_error.last.to_f.round(9).to_s.split(".").map{|p| p.to_i}
      parts[1] = parts[1] * sign

      # Sometimes setting the clock back fails so we need to handle the case
      unless adjOffset(*parts)
        # Most likely we have a small negative nsec offset and 0 sec offset
        if parts[0] == 0 && parts[1] < 0
          # Try another hacky way...
          unless adjOffset(-1,0) && adjOffset(0,1_000_000_000 + parts[1])
            # TODO: Handle this case
            # Bad things happen for unknown reasons :(
            @log.error "Unable to adjust time offset"
          end
        end
      end

      # Final cleanup
      @activestamps.fill(nil,0,4)
    end

    # Convert sec and nsec to a BigDecimal number for better than float
    # precision when calculating times
    def timeArrToBigDec(sec, nsec)
      time  = BigDecimal.new(sec, 9 + sec.floor.to_s.length)
      timen = BigDecimal.new(nsec,9 + sec.floor.to_s.length)
      timen = timen.mult(BigDecimal.new(1e-9, 16), 10)
      time + timen
    end

    # Get the HW address of interface
    def getMAC(interface)
      cmd = `ifconfig #{interface}`
      mac = cmd.match(/(([A-F0-9]{2}:){5}[A-F0-9]{2})/i).captures
      @log.debug "MAC of interface '#{interface}' is: #{mac.first}"
      return mac.first
    end

    # Get IP address of interface
    def getIP(interface)
      cmd = `ip addr show #{interface}`
      ip = cmd.match(/inet ((\d{1,3}\.){3}\d{1,3})\/\d{1,2}/).captures
      @log.debug "IP of interface '#{interface}' is: #{ip.first}"
      return ip.first
    end

    # Extract software and hardware timestamps from the ancillary data.
    # The reason for these being little endian and not network byte order, I
    # don't really get, but it works.
    def getTimestamps(cfg)
      hw_ts = nil
      sw_ts = nil
      cfg.each do |c|
        # Here, the first two 64-bit fields are sw stamps, two are not used,
        # and the last two contains the hw stamp we are looking for.
        if c.cmsg_is?(:SOCKET, Socket::SO_TIMESTAMPING)
          hw_ts = c.data.unpack("q*")[4..5]
        elsif c.cmsg_is?(:SOCKET, Socket::SO_TIMESTAMPNS)
          sw_ts = c.data.unpack("qq")
        end

        return sw_ts,hw_ts
      end
    end

    # Construct a DELAY_REQ message, set parameters for ID and send while
    # recording timestamp
    def sendDelayReq
      msg = Message.new
      msg.sourcePortIdentity = @portIdentity
      @sequenceId = (@sequenceId + 1) % 0xffff
      packet = msg.readyMessage(Message::DELAY_REQ, @sequenceId)
      @event_socket.send(packet, 0, PTP_MULTICAST_ADDR, EVENT_PORT)

      now = clock_gettime
      return [now[0] + TAI_OFFSET, now[1]]
    end

    # Get system time via c
    def clock_gettime
      #now = Time.now.utc
      #[now.to_i, now.usec]

      #ChangeTime.new.get().to_s.split(".").map!(&:to_i)

      #t = [0,0].normalize!
      t = [0,0]
      ChangeTime.new.gett(t)
      t
      #t = ChangeTime.new.get()
      #sec, nsec = t.unpack("qq")
      #timeArrToBigDec(sec,nsec)
    end

    # Adjust system time
    def adjOffset(sec,nsec)
      @log.info "Adjusting time #{sec} sec and #{nsec} nsec"
      ret = ChangeTime.new.phase(sec,nsec)
      return ret < 0 ? false : true
    end

  end
end


