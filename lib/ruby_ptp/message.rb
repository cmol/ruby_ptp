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
      if options && options[:parse]
        parse(options[:parse])
      else
        # Are we making a new packet?
      end
    end

    def parse msg
      header  = msg[0..33]
      payload = msg[34..-1]

      # Firstly unpack the header
      tmp_tran_type, @versionPTP, @messageLength, @domainNumber, res1,
        @flagField, @correctionField, res2, spi1, spi2, @sequenceId,
        @controlField, @logMessageInterval = header.unpack("CCSCCSQLQSSCC")

      # Fixup fields of 4 bits or not in 2^n octets
      @transport = tmp_tran_type >> 4
      @messageType = tmp_tran_type & 0xf
      res1 = nil; res2 = nil
      @sourcePortIdentity = (spi1 << 64) | spi2

      # Parse the payload specifics of the message
      case @messageType

      # Parse SYNC and FOLLOW_UP, and DELAY_REQ as one since they are mostly
      # identical anyway.
      when SYNC, FOLLOW_UP, DELAY_REQ
        sec1, sec2, nsec = payload.unpack("LSL")
        sec = (sec1 << 16) | sec2

        # Check if the sending clock is a two-step
        if sec == 0 && nsec == 0
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
  end
end
