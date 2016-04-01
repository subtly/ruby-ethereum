# -*- encoding : ascii-8bit -*-

module Ethereum
  ##
  # An object representing the state. In serenity, the state will be just a
  # trie of accounts with storage; ALL intermediate state, including gas used,
  # logs, transaction index, etc., is placed into contracts. This greatly
  # simplifies a large amount of handling code.
  #
  class State

    include Constant
    include Config

    attr :db

    @@transition_cache_map = {}

    def initialize(state_root, db)
      @db = db

      @state = Trie.new db
      @state.set_root_hash state_root

      # The state uses a journaling cache data structure in order to facilitate
      # revert operations while maintaining very high efficiency for updates.
      # Note that the cache is designed to handle commits happening at any
      # time; commits can be reverted too. Committing is done automatically
      # whenever a root is requested; for this reason, use the State.root
      # method to get the root instead of poking into State.state.root_hash
      # directly.
      @journal = []
      @cache = Hash.new {|h, k| h[k] = {} }
      @modified = Hash.new {|h, k| h[k] = {} }
    end

    def set_gas_limit(gas_limit, left_bound=0)
      set_storage Utils.shardify(EXECUTION_STATE, left_bound), GAS_REMAINING, gas_limit
    end

    ##
    # Call a method of a function with no effect.
    #
    def call_method(addr, ct, fun, args, gas: 1000000)
      data = ct.encode fun, args
      cd = VM::CallData.new Utils.bytes_to_int_array(data), 0, data.size
      message = VM::Message.new CONST_CALL_SENDER, addr, 0, gas, cd

      call = VM::Call.new clone
      result, gas_remained, data = call.apply_msg message, get_code(addr)

      output = Utils.int_array_to_bytes data
      ct.decode(fun, output)[0]
    end

    def call_casper(fun, args, gas: 1000000)
      call_method CASPER, Casper.contract, fun, args, gas: gas
    end

    # Accepts any state less thatn ENTER_EXIT_DELAY blocks old
    def block_valid?(block)
      guardian_index = Casper.get_guardian_index self, block.number
      guardian_address = call_casper 'getGuardianAddress', [guardian_index]
      guardian_code = call_casper 'getGuardianValidationCode', [guardian_index]
      raise AssertError, "guardian code must be bytes" unless guardian_code.instance_of?(String)

      # Check block proposer correctness
      if block.proposer != Utils.normalize_address(guardian_address)
        Utils.debug "Block proposer check for #{block.number} failed: actual #{Utils.encode_hex(block.proposer)} desired #{guardian_address}"
        return false
      end

      # Check signature correctness
      cd = VM::CallData.new Utils.bytes_to_int_array(Utils.keccak256(Utils.zpad_int(block.number) + block.txroot) + block.sig), 0, 32+block.sig.size
      message = VM::Message.new NULL_SENDER, Address::ZERO, 0, 1000000, cd
      _, _, signature_check_result = VM::StaticCall.instance.apply_msg message, guardian_code
      if signature_check_result != [0]*31 + [1]
        Utils.debug "Block signature check failed. Actual result: #{signature_check_result}"
        return false
      end

      true
    end

    ##
    # Processes a block on top of a state to reach a new state
    #
    def block_state_transition(block, listeners: [])
      pre = root

      # Determine the current block number, block proposer and block hash
      blknumber = Utils.big_endian_to_int get_storage(BLKNUMBER, 0)
      blkproposer = block ? block.proposer : "\x00"*ADDR_BYTES
      blkhash = block ? block.full_hash : WORD_ZERO

      if blknumber.true?
        set_storage STATEROOTS, Utils.zpad_int(blknumber-1), pre
      end

      set_storage PROPOSER, 0, blkproposer

      if block
        raise AssertError, 'invalid block number' unless block.number == blknumber

        # Initialize the GAS_CONSUMED variable to **just** the sum of intrinsic
        # gas of each transaction (ie. tx data consumption only, not computation)
        block.summaries.zip(block.transaction_groups).each do |s, g|
          c_exstate = Utils.shardify EXECUTION_STATE, s.left_bound
          c_log = Utils.shardify LOG, s.left_bound

          # Set the txindex to 0 to start off
          set_storage c_exstate, TXINDEX, 0

          # Initialize the gas remaining variable
          set_gas_limit s.gas_limit - s.intrinsic_gas, s.left_bound

          tx_sum = block.transaction_groups.map(&:size).reduce(0, &:+)
          gas_sum = block.summaries.map(&:intrinsic_gas).reduce(0, &:+)
          puts "Block #{blknumber} contains #{tx_sum} transactions and #{gas_sum} intrinsic gas"
          g.each do |tx|
            tx_state_transition tx, left_bound: s.left_bound, right_bound: s.right_bound, listeners: listeners
          end
          raise AssertError, 'txindex mismatch' unless Utils.big_endian_to_int(get_storage(c_exstate, TXINDEX)) == g.size

          g.size.times {|i| raise AssertError, 'missing log' unless get_storage(c_log, i).true? }
        end
      end

      set_storage BLOCKHASHES, Utils.zpad_int(blknumber), blkhash
      set_storage BLKNUMBER, 0, Utils.zpad_int(blknumber + 1) # put next block number in storage

      # Update the RNG seed (the lower 64 bits contains the number of
      # validators, the upper 192 bits are pseudorandom)
      seed_index = blknumber.true? ? Utils.zpad_int(blknumber-1) : WORD_ZERO
      prevseed = get_storage RNGSEEDS, seed_index
      newseed = Utils.big_endian_to_int Utils.keccak256(prevseed + blkproposer)
      newseed = newseed - (newseed % 2**64) + Utils.big_endian_to_int(get_storage(CASPER, 0))
      set_storage RNGSEEDS, Utils.zpad_int(blknumber), newseed

      # Consistency checking
      check_key = pre + (block ? block.full_hash : 'NONE')
      if @@transition_cache_map.has_key?(check_key)
        raise AssertError, 'inconsistent block transition' unless @@transition_cache_map[check_key] == root
      else
        @@transition_cache_map[check_key] = root
      end
    end

    def tx_state_transition(tx, left_bound: 0, right_bound: MAXSHARDS, listeners: [], breaking: false, override_gas: 2**255)
      c_exstate = Utils.shardify EXECUTION_STATE, left_bound
      c_log = Utils.shardify LOG, left_bound

      txindex = Utils.big_endian_to_int get_storage(c_exstate, TXINDEX)
      gas_remaining = Utils.big_endian_to_int get_storage(c_exstate, GAS_REMAINING) # block gas limit

      # if there's not enough gas left for this transaction, it's a no-op
      if gas_remaining < tx.exec_gas
        puts "UNABLE TO EXECUTE transaction due to gas limits: #{gas_remaining} have, #{tx.exec_gas} required"
        set_storage c_log, txindex, RLP.encode([Utils.encode_int(0)])
        set_storage c_exstate, TXINDEX, txindex+1
        return
      end

      # if the receipient is out of range, it's a no-op
      shard_id = Utils.get_shard tx.addr
      unless shard_id >= left_bound && shard_id < right_bound
        puts "UNABLE TO EXECUTE transaction due to out-of-range"
        set_storage c_log, txindex, RLP.encode([Utils.encode_int(0)])
        set_storage c_exstate, txindex, txindex+1
        return
      end

      set_storage c_exstate, TXGAS, Utils.zpad_int(tx.gas)
      call = VM::Call.new self, listeners: listeners

      # Empty the log store
      set_storage c_log, txindex, RLP::EMPTYLIST

      # Create the account if it does not yet exist
      if tx.code.true? && get_storage(tx.addr, BYTE_EMPTY).false?
        cd = VM::CallData.new [], 0, 0
        message = VM::Message.new NULL_SENDER, tx.addr, 0, tx.exec_gas, cd,
          left_bound: left_bound, right_bound: right_bound
        message.gas = [message.gas, override_gas].min

        result, execution_start_gas, data = call.apply_msg message, tx.code, breaking: breaking

        if result.false?
          set_storage c_log, txindex, RLP.encode([Utils.encode_int(1)])
          set_storage c_exstate, TXINDEX, txindex+1
          return
        end

        code = Utils.int_array_to_bytes data
        put_code tx.addr, code
      else
        execution_start_gas = [tx.exec_gas, override_gas].min
      end

      # Process VM execution
      cd = VM::CallData.new Utils.bytes_to_int_array(tx.data), 0, tx.data.size
      message = VM::Message.new NULL_SENDER, tx.addr, 0, execution_start_gas, cd
      raise AssertError, "log is not empty" unless get_storage(c_log, txindex) == RLP::EMPTYLIST

      result, msg_gas_remained, data = call.apply_msg message, get_code(tx.addr), breaking: breaking
      raise AssertError, "inconsistent gas" unless msg_gas_remained >= 0 && execution_start_gas >= msg_gas_remained && tx.exec_gas >= execution_start_gas

      # Set gas used
      set_storage c_exstate, GAS_REMAINING, gas_remaining - tx.exec_gas + msg_gas_remained

      # Places a log in storage
      logs = get_storage c_log, txindex
      set_storage c_log, txindex, RLP.insert(logs, 0, Utils.encode_int(result.true? ? 2 : 1))
      set_storage c_exstate, TXINDEX, txindex+1

      data
    end

    def root
      commit
      @state.root_hash
    end

    def clone
      commit
      self.class.new @state.root_hash, DB::OverlayDB.new(@state.db)
    end

    def unhash(hash)
      @db.get(UNHASH_MAGIC_BYTES + hash)
    end

    def puthashdata(data)
      @db.put(UNHASH_MAGIC_BYTES + Utils.keccak256(data), data)
    end

    def get_code(address)
      codehash = get_storage address, BYTE_EMPTY
      codehash.true? ? unhash(codehash) : BYTE_EMPTY
    end

    def put_code(address, code)
      codehash = Utils.keccak256 code
      @db.put(UNHASH_MAGIC_BYTES + codehash, code)
      set_storage address, BYTE_EMPTY, codehash
    end

    def get_storage(addr, k)
      k = Utils.zpad_int(k) if k.is_a?(Integer)
      addr = Utils.normalize_address addr

      return @cache[addr][k] if @cache[addr].has_key?(k)

      t = Trie.new @state.db
      t.set_root_hash @state[addr]

      v = t[k]
      @cache[addr][k] = v
      v
    end

    def set_storage(addr, k, v)
      k = Utils.zpad_int(k) if k.is_a?(Integer)
      v = Utils.zpad_int(v) if v.is_a?(Integer)

      addr = Utils.normalize_address addr
      @journal.push [addr, k, get_storage(addr, k)]
      @cache[addr][k] = v
      @modified[addr][k] = true
    end

    def commit
      root = @state.root_hash

      @cache.each do |addr, cache|
        t = Trie.new @state.db
        t.set_root_hash @state[addr]
        modified = false

        cache.each do |k, v|
          if @modified[addr].has_key?(k) && v != t[k]
            t[k] = v
            modified = true
          end
        end

        @state[addr] = t.root_hash if modified
      end

      @journal.push ['~root', [@cache, @modified], root]
      @cache = Hash.new {|h, k| h[k] = {} }
      @modified = Hash.new {|h, k| h[k] = {} }
    end

    def to_h
      state_dump = {}

      @state.to_h.each do |address, acct_root|
        acct_dump = {}
        acct_trie = Trie.new @state.db
        acct_trie.set_root_hash acct_root

        acct_trie.each do |k, v|
          acct_dump[Utils.encode_hex(k)] = Utils.encode_hex(v)
        end

        state_dump[Utils.encode_hex(address)] = acct_dump
      end

      @cache.each do |address, cache|
        key = Utils.encode_hex address
        state_dump[key] = {} unless state_dump.has_key?(key)

        cache.each do |k, v|
          state_dump[key][Utils.encode_hex(k)] = Utils.encode_hex(v) if v.true?
        end

        state_dump.delete(key) if state_dump[key].false?
      end

      state_dump
    end

    def account_to_h(account)
      addr = Utils.normalize_address account
      acct_trie = Trie.new @state.db
      acct_trie.set_root_hash @state[addr]

      acct_dump = {}
      acct_trie.each do |k, v|
        acct_dump[Utils.encode_hex(k)] = Utils.encode_hex(v)
      end

      if @cache.has_key?(addr)
        @cache[addr].each do |k, v|
          if v.true?
            acct_dump[k] = v
          else
            acct_dump.delete k if acct_dump.has_key?(k)
          end
        end
      end

      acct_dump
    end

    ##
    # Returns a value x, where State#revert at any later point will return you
    # to the point at which the snapshot was made.
    #
    def snapshot
      @journal.size
    end

    def revert(snapshot)
      while @journal.size > snapshot
        addr, key, preval = @journal.pop
        if addr == '~root'
          @state.set_root_hash = preval
          @cache, @modified = key
        else
          @cache[addr][key] = preval
        end
      end
    end

  end
end
