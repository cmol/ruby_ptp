require 'socket'
require 'inline'
require 'ipaddr'
require 'thread'

module RubyPtp


  class Port
    attr_reader :state, :ipaddr, :ts_mode

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


    @state = STATES[:INITIALIZING]

    def initialize options = {}
      @ipaddr = getIP(options[:interface])

      @ts_mode = options[:ts_mode]
      @event_socket = setup_event_socket(options[:interface])

      @general_socket = UDPSocket.new
      @general_socket.setsockopt(:SOCKET,
                             Socket::IP_MULTICAST_IF, IPAddr.new(@ipaddr).hton)
      @general_socket.bind(@ipaddr, GENERAL_PORT)


      @state = STATES[:SLAVE]
    end

    def startPtp options = {}
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
          sw_ts = Time.now.utc
          parseEvent(msg, addr, rflags, cfg, sw_ts)
        end
        @event_socket.close
      end

      Thread.join(general)
      Thread.join(event)
    end

    private


    # Either setup socket in HW or SW timestamping mode
    def setupEventSocket
      if @ts_mode == :TIMESTAMPHW
        raise NotImplementedError.new("HW TIMESTAMPS")

      else
        socket = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
        socket.setsockopt(:SOCKET,
                          Socket::IP_MULTICAST_IF, IPAddr.new(@ipaddr).hton)
        socket.setsockopt(:SOCKET, :TIMESTAMPINGNS, true)
      end

      socket.bind(@ipaddr, EVENT_PORT)
      return socket
    end

    def getMessage(msg)
      RubyPtp::Message.new(parse: msg)
    end

    def parseEvent(msg, addr, rflags, cfg, sw_ts)
      message = getMessage(msg)

      # Figure out what to do with the packages
      case message.type

      # In case of a SYNC
      when RubyPtp::Message.SYNC
      when RubyPtp::Message.FOLLOW_UP
      when RubyPtp::Message.DELAY_RESP
      end
    end

    def parseGeneral(msg, addr, rflags, cfg)
      message = getMessage(msg)

      case message.type
      when ANNOUNC
      end
    end


  end
end


