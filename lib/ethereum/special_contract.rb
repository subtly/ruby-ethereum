# -*- encoding : ascii-8bit -*-

module Ethereum
  class SpecialContract

    class ECRecover
      def call(ext, msg)
        gas_cost = Opcodes::GECRECOVER
        return 0, 0, [] if msg.gas < gas_cost

        b = []
        msg.data.extract_copy(b, 0, 0, 32)

        h = Utils.int_array_to_bytes b
        v = msg.data.extract32(32)
        r = msg.data.extract32(64)
        s = msg.data.extract32(96)

        if r >= Secp256k1::N || s >= Secp256k1::N || v < 27 || v > 28
          return 1, msg.gas - gas_cost, []
        end

        recovered_addr = Secp256k1.ecdsa_raw_recover(h, [v,r,s]) rescue nil
        if recovered_addr.nil? || recovered_addr == [0,0]
          return 1, msg.gas - gas_cost, []
        end

        pub = PublicKey.new(recovered_addr).encode(:bin)
        pubhash = Utils.keccak256(pub[1..-1])[-20..-1]
        o = Utils.bytes_to_int_array Utils.zpad(pubhash, 32)

        return 1, msg.gas - gas_cost, o
      end
    end

    class SHA256
      def call(ext, msg)
        gas_cost = Opcodes::GSHA256BASE +
          (Utils.ceil32(msg.data.size) / 32) * Opcodes::GSHA256WORD
        return 0, 0, [] if msg.gas < gas_cost

        d = msg.data.extract_all
        o = Utils.bytes_to_int_array Utils.sha256(d)

        return 1, msg.gas - gas_cost, o
      end
    end

    class RIPEMD160
      def call(ext, msg)
        gas_cost = Opcodes::GRIPEMD160BASE +
          (Utils.ceil32(msg.data.size) / 32) * Opcodes::GRIPEMD160WORD
        return 0, 0, [] if msg.gas < gas_cost

        d = msg.data.extract_all
        o = Utils.bytes_to_int_array Utils.zpad(Utils.ripemd160(d), 32)

        return 1, msg.gas - gas_cost, o
      end
    end

    class Identity
      def call(ext, msg)
        gas_cost = Opcodes::GIDENTITYBASE +
          (Utils.ceil32(msg.data.size) / 32) * Opcodes::GIDENTITYWORD
        return 0, 0, [] if msg.gas < gas_cost

        o = []
        msg.data.extract_copy(o, 0, 0, msg.data.size)

        return 1, msg.gas - gas_cost, o
      end
    end

    DEPLOY = {
      '0000000000000000000000000000000000000001' => ECRecover.new,
      '0000000000000000000000000000000000000002' => SHA256.new,
      '0000000000000000000000000000000000000003' => RIPEMD160.new,
      '0000000000000000000000000000000000000004' => Identity.new
    }.map {|k,v| [Utils.decode_hex(k), v] }.to_h.freeze

    class <<self
      def [](address)
        DEPLOY[address]
      end
    end

  end
end
