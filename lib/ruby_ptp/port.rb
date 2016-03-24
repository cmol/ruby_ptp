require 'socket'
require 'inline'
require 'ipaddr'

module RubyPtp


  class Port
    attr_reader :state, :ipaddr, :ts_mode

    PTP_MULTICAST_ADDR = "224.0.1.129"
    EVENT_PORT         = 319
    GENERAL_PORT       = 320
    SIOCSHWTSTAMP      = 0x89b0


    @state = :INITIALIZING

    def initialize options = {}
      @ipaddr = getIP(options[:interface])

      @ts_mode = options[:ts_mode]
      @event_socket = setup_event_socket(options[:interface])
      @general_socket = UDPSocket.new
      @general_socket.bind(@ipaddr, GENERAL_PORT)
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

  end
end


