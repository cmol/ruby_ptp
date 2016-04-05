require 'socket'
require 'inline'
require 'ipaddr'
require 'thread'
require 'bigdecimal'

module RubyPtp

  class Port
    attr_reader :state, :ipaddr, :ts_mode, :slave_state, :timestamps,
      :savestamps, :activestamps, :delay, :phase_error, :freq_error

    PTP_MULTICAST_ADDR = "224.0.1.129"
    EVENT_PORT         = 319
    GENERAL_PORT       = 320
    SIOCSHWTSTAMP      = 0x89b0

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
      @phase_error   = []
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

      # We are only running in slave mode
      @state = STATES[:SLAVE]
    end

    def startPtp options = {}
      Thread.abort_on_exception = true
      general = Thread.new do
        while @state == STATES[:SLAVE] do
          msg, addr, rflags, *cfg = @general_socket.recvmsg
          parseGeneral(msg, addr, rflags, cfg)
        end
        @general_socket.close
      end

      event = Thread.new do
        while @state == STATES[:SLAVE] do
          msg, addr, rflags, *cfg = @event_socket.recvmsg

          # TODO:Right now we'll just use SW TS to get things going and then do
          # something smarter when to protocol is working
          sw_ts = Time.now.utc
          parseEvent(msg, addr, rflags, cfg, [sw_ts.to_i, sw_ts.usec])
        end
        @event_socket.close
      end

      general.join
      event.join
    end

    private


    # Either setup socket in HW or SW timestamping mode
    def setupEventSocket(interface)
      if @ts_mode == :TIMESTAMPHW
        raise NotImplementedError.new("HW TIMESTAMPS")

      else
        #socket = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
        #socket.setsockopt(:SOCKET,
        #                  Socket::IP_MULTICAST_IF, IPAddr.new(@ipaddr).hton)
        socket = UDPSocket.new
        socket.setsockopt(:SOCKET, :TIMESTAMPNS, true)
        ip = IPAddr.new(PTP_MULTICAST_ADDR).hton + IPAddr.new("0.0.0.0").hton
        socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, ip)
        socket.bind(Socket::INADDR_ANY, EVENT_PORT)
      end

      #socket.bind(Addrinfo.udp(@ipaddr, EVENT_PORT))
      return socket
    end

    def getMessage(msg)
      Message.new(parse: msg)
    end

    def parseEvent(msg, addr, rflags, cfg, ts)
      message = getMessage(msg)
      puts message.inspect

      # Figure out what to do with the packages
      case message.type

      # In case of a SYNC
      when Message::SYNC
        if @slave_state == :WAIT_FOR_SYNC
          if message.originTimestamp == -1
            @slave_state = :WAIT_FOR_FOLLOW_UP
            recordTimestamps(t2: timeArrToBigDec(*ts))
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

      puts @slave_state
    end

    def parseGeneral(msg, addr, rflags, cfg)
      message = getMessage(msg)
      puts message.inspect

      case message.type
      when Message::ANNOUNCE
        # bob...

      # In case of a FOLLOW_UP
      when Message::FOLLOW_UP
        if @slave_state == :WAIT_FOR_FOLLOW_UP
          recordTimestamps(t1: timeArrToBigDec(*message.originTimestamp))
          t3 = sendDelayReq()
          recordTimestamps(t3: timeArrToBigDec(*t3))
          @slave_state = :WAIT_FOR_DELAY_RESP
        end
      # In case of a DELAY_RESP
      when Message::DELAY_RESP
        if @slave_state == :WAIT_FOR_DELAY_RESP
          recordTimestamps(t4: timeArrToBigDec(*message.receiveTimestamp))
          updateTime()
          @slave_state = :WAIT_FOR_SYNC
        end
      end

      puts @slave_state
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

      # Calculate link delay
      @delay << ((t2 - t1) + (t4 - t3)) / 2
      # Calculate phase error
      @phase_error << ((t2 - t1) - (t4 - t3)) / 2

      # Calculate frequency error
      if @timestamps[-2]
        old = @timestamps[-2]
        old_delay = @delay[-2]
        @freq_error << ((@activestamps[0] - old[0]) / (
                      (@activestamps[1] + delay) -
                      (old[1] + old_delay)))
      end

      # TODO: Update system
      puts @delay.last
      puts @phase_error.last
      puts @freq_error.last

      # Final cleanup
      @activestamps.fill(nil,0,4)
    end

    def timeArrToBigDec(sec, nsec)
      time  = BigDecimal.new(sec, 9 + sec.floor.to_s.length)
      timen = BigDecimal.new(nsec,9 + sec.floor.to_s.length)
      timen = timen.div(1e9)
      time + timen
    end

    def getMAC(interface)
      cmd = `ifconfig #{interface}`
      mac = cmd.match(/(([A-F0-9]{2}:){5}[A-F0-9]{2})/i).captures
      return mac.first
    end

    def getIP(interface)
      cmd = `ip addr show #{interface}`
      ip = cmd.match(/inet ((\d{1,3}\.){3}\d{1,3})\/\d{1,2}/).captures
      return ip.first
    end

    def sendDelayReq
      msg = Message.new
      msg.sourcePortIdentity = @portIdentity
      @sequenceId = (@sequenceId + 1) % 0xffff
      packet = msg.readyMessage(Message::DELAY_REQ, @sequenceId)
      @event_socket.send(packet, 0, PTP_MULTICAST_ADDR, EVENT_PORT)
      now = Time.now.utc
      return [now.to_i, now.usec]
    end
  end
end


