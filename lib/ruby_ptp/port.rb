require 'socket'
require 'inline'
require 'ipaddr'
require 'thread'
require 'bigdecimal'
require 'logger'
require 'fcntl'

module RubyPtp

  class Port
    attr_reader :state, :ipaddr, :ts_mode, :slave_state, :timestamps,
      :savestamps, :activestamps, :delay, :phase_error, :freq_error

    PTP_MULTICAST_ADDR = "224.0.1.129"
    EVENT_PORT         = 319
    GENERAL_PORT       = 320
    SIOCSHWTSTAMP      = 0x89b0
    TAI_OFFSET         = 0 # TAI is 36 seconds in front of UTC
    ALPHA              = BigDecimal.new(0.98,9)
    ALPHA_FREQ         = BigDecimal.new(0.999,9)

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
      @announce_counter = 0

      # Set mode of timestamps
      @ts_mode = options[:ts_mode]

      # Ready object for saving timestamps
      @savestamps    = options[:savestamps] || 3
      @timestamps    = []
      @delay         = []
      @phase_error   = []
      @phase_err_avg = []
      @freq_error    = []
      @freq_err_avg  = [1]
      @sync_id       = -1
      @activestamps  = [].fill(nil, 0, 4)

      # State "timer" test
      @flipflop     = 0
      @flipflopeach = 5

      # Create event socket
      @event_socket = setupEventSocket(options[:interface])
      @clock_id     = getClockId(options[:phc])

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
      end

      @log.debug "Starting event thread"
      event = Thread.new do
        while @state == STATES[:SLAVE] do
          msg, addr, rflags, *cfg = @event_socket.recvmsg

          # Use the timestamps from the system, just in case we need it
          sw_ts = clock_gettime
          parseEvent(msg, addr, rflags, cfg, sw_ts)
        end
      end

      Signal.trap("INT") {
        @state = STATES[:DISABLED]

        data = [
          {name: "delay", data: @delay},
          {name: "phase_err", data: @phase_error},
          {name: "phase_err_avg", data: @phase_err_avg},
          {name: "freq_err", data: @freq_error},
          {name: "freq_err_avg", data: @freq_err_avg}
        ]

        RubyPtp::Helper.write_data(files: data,
                                   path: "/home/cmol/DTU/bachalor/data/")
        puts "Trying gracefull shutdown (2sec)"
        @general_socket.close
        @event_socket.close
        sleep(2)
        event.terminate unless @event_socket.closed?
        general.terminate unless @general_socket.closed?
      }

      general.join
      event.join
    end

    private

    # Get clock_id of phc
    def getClockId(path)
      return 0 unless path
      fd = IO.sysopen(path, Fcntl::O_RDWR)
      # From missing.h in linuxptp
      fd
    end

    # Either setup socket in HW or SW timestamping mode
    def setupEventSocket(interface)
      socket = UDPSocket.new
      ip = IPAddr.new(PTP_MULTICAST_ADDR).hton + IPAddr.new("0.0.0.0").hton
      socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, ip)

      # If we are trying to do HW stamps, we need to initialise the network
      # interface to actually make the timestamps.
      if @ts_mode == :TIMESTAMPHW || true

        # Construct the command for the network interface in a slightly crude
        # way according to:
        # https://www.kernel.org/doc/Documentation/networking/timestamping.txt
        hwstamp_config = [0,1,1].pack("iii")
        ifreq = interface.ljust(16,"\x00") + [hwstamp_config].pack("P")
        # Make sure things worked
        if socket.ioctl(SIOCSHWTSTAMP, ifreq) != 0
          @log.error "Unable to initialise HW stamping"
        end
        socket.setsockopt(:SOCKET, Socket::SO_TIMESTAMPING, 69)
        #socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_LOOP, true)
      end

      # Enable the software timestamps for comparison
      socket.setsockopt(:SOCKET, :TIMESTAMPNS, true)
      socket.bind(Socket::INADDR_ANY, EVENT_PORT)

      return socket
    end

    def getMessage(msg)
      Message.new(parse: msg)
    end

    def parseEvent(msg, addr, rflags, cfg, now)
      message = getMessage(msg)
      @log.debug message.inspect

      # Get timestamps from socket
      sw_ts, hw_ts = getTimestamps(cfg)

      # Firstly try the TIMESTAMPNS
      now = sw_ts if sw_ts

      # Try to get hardware timestamps if we have them
      if @ts_mode == :TIMESTAMPHW
        if hw_ts == nil
          @log.error "No hardware timestamps in recived SYNC. " \
            "Using software"
        else
          now = hw_ts
        end
      end
      now = [now[0] + TAI_OFFSET, now[1]]

      # Figure out what to do with the packages
      case message.type

      # In case of a SYNC
      when Message::SYNC
        if @slave_state == :WAIT_FOR_SYNC ||
            (message.sequenceId > @sync_id &&
             @slave_state == :WAIT_FOR_FOLLOW_UP)
          if message.originTimestamp == -1

            # In case the follow_up arrives first we need to deal with changing
            # the order in which we are working. When the sequence ID is
            # already up to date, we'll go straight to delay_req as we should
            # already have t1 recorded somewhere.
            recordTimestamps(t2: timeArrToBigDec(*now))
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
            t2 = timeArrToBigDec(*now)
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
        @announce_counter += 1
        if @announce_counter > 2 && @slave_state == :WAIT_FOR_DELAY_RESP
          @log.debug "We might be stuck, start over with sync"
          @slave_state = :WAIT_FOR_SYNC
          @announce_counter = 0
        end

      # In case of a FOLLOW_UP
      when Message::FOLLOW_UP
        if @slave_state == :WAIT_FOR_FOLLOW_UP ||
           (@slave_state == :WAIT_FOR_SYNC && @sync_id < message.sequenceId)
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
      @timestamps << @activestamps.map {|s| s.to_f}

      t1, t2, t3, t4 = @activestamps
      @log.debug "t1: #{t1.to_f}, "\
       "t2: #{t2.to_f}, "\
       "t3: #{t3.to_f}, "\
       "t4: #{t4.to_f}"

      # Calculate link delay
      delay = ((t2 - t1) + (t4 - t3)) / BigDecimal.new(2)
      @delay << (delay.to_f > 0 ? delay : delay * -1)
      # Calculate phase error and average phase_error
      @phase_error << ((t2 - t1) - (t4 - t3)) / BigDecimal.new(2)

      # Calculate average phase error if multiple data points exists
      avg = @phase_error[-1]
      if @phase_err_avg[-1]
        avg = ALPHA * @phase_err_avg[-1] + (BigDecimal.new(1) - ALPHA) * @phase_error[-1]
      end
      @phase_err_avg << avg

      # Calculate frequency error
      distance = -2
      if @timestamps[distance]
        ot1 = @timestamps[distance][0]
        ot2 = @timestamps[distance][1]
        ode = @delay[distance].to_f
        de  = @delay.last.to_f
        error = (t1.to_f - ot1) / ((t2.to_f + de) - (ot2 + ode))
        # Do some hard filtering of data
        if error < 10 && error > 0.0
          @freq_error << error
        else
          puts "ERROR ERROR ERROR ERROR " + error.to_s
          @freq_error << @freq_error[-1] || 1
        end
      end

      # Calculate average frequency error if multiple data points exists
      if @freq_error[-1]
        avg = @freq_error[-1]
        if @freq_err_avg[-1]
          avg = ALPHA_FREQ * @freq_err_avg[-1] + (BigDecimal.new(1) - ALPHA_FREQ) * @freq_error[-1]
        end
        @freq_err_avg << avg
      end

      # TODO: Update system
      @log.info "Delay: #{@delay.last.to_f} \t" \
        "phase_err: #{@phase_error.last.to_f} \t"\
        "phase_err_avg: #{@phase_err_avg.last.to_f}, \t"\
        "freq_err: #{@freq_error.last.to_f} \t"\
        "freq_err_avg: #{@freq_err_avg.last.to_f}"

      # Adjust phase
      #adjOffset(@phase_err_avg.last.to_f)

      # Adjust frequency when we have some point of measurement
      adjFreq(@freq_err_avg.last.to_f) if @freq_err_avg[-10]

      # Final cleanup
      @activestamps.fill(nil,0,4)
    end

    # Convert sec and nsec to a BigDecimal number for better than float
    # precision when calculating times
    def timeArrToBigDec(sec, nsec)
      time  = BigDecimal.new(sec, 9 + sec.floor.to_s.length)
      timen = BigDecimal.new(nsec,9 + sec.floor.to_s.length)
      timen = timen.mult(BigDecimal.new(1e-9, 16), 9)
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

      end
      return sw_ts,hw_ts
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

      # Get timestaps from hardware
      msg, addr, rflags, *cfg = @event_socket.recvmsg(256,
                                               Socket::MSG_ERRQUEUE,
                                               512, :scm_rights=>true)
      msg = addr = rflags = nil
      sw_ts, hw_ts = getTimestamps(cfg)

      # Firstly try the TIMESTAMPNS
      now = sw_ts if sw_ts

      # Try to get hardware timestamps if we have them
      if @ts_mode == :TIMESTAMPHW
        if hw_ts == nil
          @log.error "No hardware timestamps available after Delay_Req. " \
            "Using software"
        else
          now = hw_ts
        end
      end


      return [now[0] + TAI_OFFSET, now[1]]
    end

    # Get system time via c
    def clock_gettime
      t = [0,0]
      ChangeTime.new.gett(t)
      t
    end

    # Adjust system time
    def adjOffset(adj)
      @log.info "Adjusting time #{adj} sec"
      ret = ChangeTime.new.phase_adj(adj, @clock_id)
      @log.info ret.to_s
    end

    # Adjust system time
    def adjFreq(adj)
      @log.info "Adjusting frequency #{adj} parts (relative to current)"
      ret = ChangeTime.new.freq_adj(adj, @clock_id)
      @log.info ret.to_s
    end

  end
end

