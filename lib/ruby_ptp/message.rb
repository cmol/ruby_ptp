module RubyPtp
  class Message
    attr_accessor :transport, :messageType, :versionPTP, :messageLength,
      :domainNumber, :flagField, :correctionField, :sourcePortIdentity,
      :sequenceId, :controlField, :logMessageInterval, :originTimestamp,
      :receiveTimestamp, :requestingPortIdentity

    alias_attribute :type, :messageType

    # Define message types
    SYNC                  = 0x0
    DELAY_REQ             = 0x1
    PDELAY_REQ            = 0x2
    PDELAY_RESP           = 0x3
    FOLLOW_UP             = 0x8
    DELAY_RESP            = 0x9
    PDELAY_RESP_FOLLOW_UP = 0xa
    ANNOUNCE              = 0xb
    SIGNALING             = 0xc
    MANAGEMENT            = 0xd

    def initialize options = {}
      if options[:parse]
        parse(options[:parse])
      else
        # We are making a new packet
        @flagField = 0x0000
        @versionPTP = 0x2
        @domainNumber = 0x0
        @sourcePortIdentityPortNumer = 0x1
      end
    end

    def parse msg
      header  = msg[0..33]
      payload = msg[34..-1]

      # Firstly unpack the header
      tmp_tran_type, @versionPTP, @messageLength, @domainNumber, res1,
        @flagField, @correctionField, res2, @sourcePortIdentity, portno,
        @sequenceId, @controlField,
        @logMessageInterval = header.unpack("CCS>CCS>Q>L>Q>S>S>CC")

      # Fixup fields of 4 bits or not in 2^n octets
      @transport = tmp_tran_type >> 4
      @messageType = tmp_tran_type & 0xf
      res1 = nil; res2 = nil; portno = nil

      # Parse the payload specifics of the message
      case @messageType

      # Parse SYNC and FOLLOW_UP, and DELAY_REQ as one since they are mostly
      # identical anyway.
      when SYNC, FOLLOW_UP, DELAY_REQ
        sec1, sec2, nsec = payload.unpack("LSL")
        sec = (sec1 << 16) | sec2

        # Check if the sending clock is a two-step
        if (@flagField & 1) == 1 || sec == 0 && nsec == 0
          @originTimestamp = -1
        else
          @originTimestamp = [sec, nsec]
        end

      when PDELAY_REQ
        raise NotImplementedError.new("PDELAY_REQ")
      when PDELAY_RESP
        raise NotImplementedError.new("PDELAY_RESP")
      when DELAY_RESP
        sec1, sec2, nsec, rpi1, rpi2 = payload.unpack("LSLQS")
        sec = (sec1 << 16) | sec2
        rpi = (rpi1 << 32) | rpi2

        @receiveTimestamp = [sec,nsec]
        @requestingPortIdentity = rpi

      when PDELAY_RESP_FOLLOW_UP
        raise NotImplementedError.new("PDELAY_RESP_FOLLOW_UP")
      when ANNOUNCE
        raise NotImplementedError.new("ANNOUNCE")
      when SIGNALING
        raise NotImplementedError.new("SIGNALING")
      when MANAGEMENT
        raise NotImplementedError.new("MANAGEMENT")

      else
        puts "Got unknown messageType: #{@messageType}"
        raise ArgumentError
      end
    end

    # Construct packet for sending and return the string to send
    def readyMessage(type)

      # Create the packet payload
      payload = nil
      case type
      when DELAY_REQ
        payload = [0x0,0x0].pack("Q>S>")

        # Set defaults for DELAY_REQ packets
        @messageType        = DELAY_REQ
        @controlField       = DELAY_REQ
        @correctionField    = 0x0
        @messageLength      = 0x2c
        @logMessageInterval = 0x7f
      end

      # Make the header for the packet
      header = [@messageType,                 # C
                @versionPTP,                  # C
                @messageLength,               # S>
                @domainNumber,                # C
                0x0,                          # C - reserved
                @flagField,                   # S>
                @correctionField,             # Q>
                0x0,                          # L> - reserved
                @sourcePortIdentity,          # Q>
                @sourcePortIdentityPortNumer, # S>
                @controlField,                # C
                @logMessageInterval           # C
        ].pack("CCS>CCS>Q>L>Q>S>CC")

      return header + payload
    end

  end
end
