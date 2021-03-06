address 0x1 {

module Libra {
    use 0x1::Vector;
    use 0x1::Transaction;

    // A resource representing a fungible token
    resource struct T<Token> {
        // The value of the token. May be zero
        value: u64,
    }

    // A singleton resource that grants access to `Libra::mint`. Only the Association has one.
    resource struct MintCapability<Token> { }

    resource struct Info<Token> {
        // The sum of the values of all Libra::T resources in the system
        total_value: u128,
        // Value of funds that are in the process of being burned
        preburn_value: u64,
    }

    // A holding area where funds that will subsequently be burned wait while their underyling
    // assets are sold off-chain.
    // This resource can only be created by the holder of the MintCapability. An account that
    // contains this address has the authority to initiate a burn request. A burn request can be
    // resolved by the holder of the MintCapability by either (1) burning the funds, or (2)
    // returning the funds to the account that initiated the burn request.
    // This design supports multiple preburn requests in flight at the same time, including multiple
    // burn requests from the same account. However, burn requests from the same account must be
    // resolved in FIFO order.
    resource struct Preburn<Token> {
        // Queue of pending burn requests
        requests: vector<T<Token>>,
        // Boolean that is true if the holder of the MintCapability has approved this account as a
        // preburner
        is_approved: bool,
    }

    public fun register<Token>() {
        // Only callable by the Association address
        assert(Transaction::sender() == 0xA550C18, 1);
        move_to_sender(MintCapability<Token>{ });
        move_to_sender(Info<Token> { total_value: 0u128, preburn_value: 0 });
    }
    spec fun register {
        aborts_if sender() != 0xA550C18;
        aborts_if exists<MintCapability<Token>>(sender());
        aborts_if exists<Info<Token>>(sender());
        ensures exists<MintCapability<Token>>(sender());
        ensures exists<Info<Token>>(sender());
        ensures global<Info<Token>>(sender()).total_value == 0;
        ensures global<Info<Token>>(sender()).preburn_value == 0;
    }

    fun assert_is_registered<Token>() {
        assert(exists<Info<Token>>(0xA550C18), 12);
    }
    spec fun assert_is_registered {
        aborts_if !exists<Info<Token>>(0xA550C18);
    }

    // Return `amount` coins.
    // Fails if the sender does not have a published MintCapability.
    public fun mint<Token>(amount: u64): T<Token> acquires Info, MintCapability {
        mint_with_capability(amount, borrow_global<MintCapability<Token>>(Transaction::sender()))
    }
    spec fun mint {
        aborts_if !exists<MintCapability<Token>>(sender());
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if amount > 1000000000 * 1000000;
        aborts_if global<Info<Token>>(0xA550C18).total_value + amount > max_u128();
        ensures global<Info<Token>>(0xA550C18).total_value == old(global<Info<Token>>(0xA550C18).total_value) + amount;
        ensures result.value == amount;
    }

    // Burn the coins currently held in the preburn holding area under `preburn_address`.
    // Fails if the sender does not have a published MintCapability.
    public fun burn<Token>(
        preburn_address: address
    ) acquires Info, MintCapability, Preburn {
        burn_with_capability(
            preburn_address,
            borrow_global<MintCapability<Token>>(Transaction::sender())
        )
    }
    spec fun burn {
        aborts_if !exists<MintCapability<Token>>(sender());
        aborts_if !exists<Preburn<Token>>(preburn_address);
        aborts_if len(global<Preburn<Token>>(preburn_address).requests) == 0;
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if global<Info<Token>>(0xA550C18).total_value < global<Preburn<Token>>(preburn_address).requests[0].value;
        aborts_if global<Info<Token>>(0xA550C18).preburn_value < global<Preburn<Token>>(preburn_address).requests[0].value;
        ensures eq_pop_front(global<Preburn<Token>>(preburn_address).requests, old(global<Preburn<Token>>(preburn_address).requests));
        ensures global<Info<Token>>(0xA550C18).total_value == old(global<Info<Token>>(0xA550C18).total_value) - old(global<Preburn<Token>>(preburn_address).requests[0].value);
        ensures global<Info<Token>>(0xA550C18).preburn_value == old(global<Info<Token>>(0xA550C18).preburn_value) - old(global<Preburn<Token>>(preburn_address).requests[0].value);
    }

    // Cancel the oldest burn request from `preburn_address`
    // Fails if the sender does not have a published MintCapability.
    public fun cancel_burn<Token>(
        preburn_address: address
    ): T<Token> acquires Info, MintCapability, Preburn {
        cancel_burn_with_capability(
            preburn_address,
            borrow_global<MintCapability<Token>>(Transaction::sender())
        )
    }
    spec fun cancel_burn {
        aborts_if !exists<MintCapability<Token>>(sender());
        aborts_if !exists<Preburn<Token>>(preburn_address);
        aborts_if len(global<Preburn<Token>>(preburn_address).requests) == 0;
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if global<Info<Token>>(0xA550C18).preburn_value < global<Preburn<Token>>(preburn_address).requests[0].value;
        ensures eq_pop_front(global<Preburn<Token>>(preburn_address).requests, old(global<Preburn<Token>>(preburn_address).requests));
        ensures global<Info<Token>>(0xA550C18).preburn_value == old(global<Info<Token>>(0xA550C18).preburn_value) - old(global<Preburn<Token>>(preburn_address).requests[0].value);
        ensures result == old(global<Preburn<Token>>(preburn_address).requests[0]);
    }

    // Create a new Preburn resource
    public fun new_preburn<Token>(): Preburn<Token> {
        assert_is_registered<Token>();
        Preburn<Token> { requests: Vector::empty(), is_approved: false, }
    }
    spec fun new_preburn {
        aborts_if !exists<Info<Token>>(0xA550C18);
        ensures len(result.requests) == 0;
        ensures result.is_approved == false;
    }

    // Mint a new Libra::T worth `value`. The caller must have a reference to a MintCapability.
    // Only the Association account can acquire such a reference, and it can do so only via
    // `borrow_sender_mint_capability`
    public fun mint_with_capability<Token>(
        value: u64,
        _capability: &MintCapability<Token>
    ): T<Token> acquires Info {
        assert_is_registered<Token>();
        // TODO: temporary measure for testnet only: limit minting to 1B Libra at a time.
        // this is to prevent the market cap's total value from hitting u64_max due to excessive
        // minting. This will not be a problem in the production Libra system because coins will
        // be backed with real-world assets, and thus minting will be correspondingly rarer.
        // * 1000000 here because the unit is microlibra
        assert(value <= 1000000000 * 1000000, 11);
        // update market cap resource to reflect minting
        let market_cap = borrow_global_mut<Info<Token>>(0xA550C18);
        market_cap.total_value = market_cap.total_value + (value as u128);

        T<Token> { value }
    }
    spec fun mint_with_capability {
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if value > 1000000000 * 1000000;
        aborts_if global<Info<Token>>(0xA550C18).total_value + value > max_u128();
        ensures global<Info<Token>>(0xA550C18).total_value == old(global<Info<Token>>(0xA550C18).total_value) + value;
        ensures result.value == value;
    }

    spec module {
        // Auxiliary function to check if `v1` is equal to the result of adding `e` at the end of `v2`
        define eq_push_back<Element>(v1: vector<Element>, v2: vector<Element>, e: Element): bool {
            len(v1) == len(v2) + 1 &&
            v1[len(v1)-1] == e &&
            v1[0..len(v1)-1] == v2[0..len(v2)]
        }

        // Auxiliary function to check if `v1` is equal to the result of removing the first element of `v2`
        define eq_pop_front<Element>(v1: vector<Element>, v2: vector<Element>): bool {
            len(v1) + 1 == len(v2) &&
            v1 == v2[1..len(v2)]
        }
    }

    // Send coin to the preburn holding area `preburn_ref`, where it will wait to be burned.
    public fun preburn<Token>(
        preburn_ref: &mut Preburn<Token>,
        coin: T<Token>
    ) acquires Info {
        // TODO: bring this back once we can automate approvals in testnet
        // assert(preburn_ref.is_approved, 13);
        let coin_value = value(&coin);
        Vector::push_back(
            &mut preburn_ref.requests,
            coin
        );
        let market_cap = borrow_global_mut<Info<Token>>(0xA550C18);
        market_cap.preburn_value = market_cap.preburn_value + coin_value
    }
    spec fun preburn {
        // aborts_if !preburn_ref.is_approved; // TODO: bring this back once we can automate approvals in testnet
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if global<Info<Token>>(0xA550C18).preburn_value + coin.value > max_u64();
        ensures global<Info<Token>>(0xA550C18).preburn_value == old(global<Info<Token>>(0xA550C18).preburn_value) + coin.value;
        ensures eq_push_back(preburn_ref.requests, old(preburn_ref.requests), coin);
    }

    // Send coin to the preburn holding area, where it will wait to be burned.
    // Fails if the sender does not have a published Preburn resource
    public fun preburn_to_sender<Token>(coin: T<Token>) acquires Info, Preburn {
        preburn(borrow_global_mut<Preburn<Token>>(Transaction::sender()), coin)
    }

    spec fun preburn_to_sender {
        // aborts_if !preburn_ref.is_approved; // TODO: bring this back once we can automate approvals in testnet
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if !exists<Preburn<Token>>(sender());
        aborts_if global<Info<Token>>(0xA550C18).preburn_value + coin.value > max_u64();
        ensures global<Info<Token>>(0xA550C18).preburn_value == old(global<Info<Token>>(0xA550C18).preburn_value) + coin.value;
        ensures eq_push_back(global<Preburn<Token>>(sender()).requests, old(global<Preburn<Token>>(sender()).requests), coin);
    }

    // Permanently remove the coins held in the `Preburn` resource stored at `preburn_address` and
    // update the market cap accordingly. If there are multiple preburn requests in progress, this
    // will remove the oldest one.
    // Can only be invoked by the holder of the MintCapability. Fails if the there is no `Preburn`
    // resource under `preburn_address` or has one with no pending burn requests.
    public fun burn_with_capability<Token>(
        preburn_address: address,
        _capability: &MintCapability<Token>
    ) acquires Info, Preburn {
        // destroy the coin at the head of the preburn queue
        let preburn = borrow_global_mut<Preburn<Token>>(preburn_address);
        let T { value } = Vector::remove(&mut preburn.requests, 0);
        // update the market cap
        let market_cap = borrow_global_mut<Info<Token>>(0xA550C18);
        market_cap.total_value = market_cap.total_value - (value as u128);
        market_cap.preburn_value = market_cap.preburn_value - value
    }
    spec fun burn_with_capability {
        aborts_if !exists<Preburn<Token>>(preburn_address);
        aborts_if len(global<Preburn<Token>>(preburn_address).requests) == 0;
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if global<Info<Token>>(0xA550C18).total_value < global<Preburn<Token>>(preburn_address).requests[0].value;
        aborts_if global<Info<Token>>(0xA550C18).preburn_value < global<Preburn<Token>>(preburn_address).requests[0].value;
        ensures eq_pop_front(global<Preburn<Token>>(preburn_address).requests, old(global<Preburn<Token>>(preburn_address).requests));
        ensures global<Info<Token>>(0xA550C18).total_value == old(global<Info<Token>>(0xA550C18).total_value) - old(global<Preburn<Token>>(preburn_address).requests[0].value);
        ensures global<Info<Token>>(0xA550C18).preburn_value == old(global<Info<Token>>(0xA550C18).preburn_value) - old(global<Preburn<Token>>(preburn_address).requests[0].value);
    }

    // Cancel the burn request in the `Preburn` resource stored at `preburn_address` and
    // return the coins to the caller.
    // If there are multiple preburn requests in progress, this will cancel the oldest one.
    // Can only be invoked by the holder of the MintCapability. Fails if the transaction sender
    // does not have a published Preburn resource or has one with no pending burn requests.
    public fun cancel_burn_with_capability<Token>(
        preburn_address: address,
        _capability: &MintCapability<Token>
    ): T<Token> acquires Info, Preburn {
        // destroy the coin at the head of the preburn queue
        let preburn = borrow_global_mut<Preburn<Token>>(preburn_address);
        let coin = Vector::remove(&mut preburn.requests, 0);
        // update the market cap
        let market_cap = borrow_global_mut<Info<Token>>(0xA550C18);
        market_cap.preburn_value = market_cap.preburn_value - value(&coin);

        coin
    }
    spec fun cancel_burn_with_capability {
        aborts_if !exists<Preburn<Token>>(preburn_address);
        aborts_if len(global<Preburn<Token>>(preburn_address).requests) == 0;
        aborts_if !exists<Info<Token>>(0xA550C18);
        aborts_if global<Info<Token>>(0xA550C18).preburn_value < global<Preburn<Token>>(preburn_address).requests[0].value;
        ensures eq_pop_front(global<Preburn<Token>>(preburn_address).requests, old(global<Preburn<Token>>(preburn_address).requests));
        ensures global<Info<Token>>(0xA550C18).preburn_value == old(global<Info<Token>>(0xA550C18).preburn_value) - old(global<Preburn<Token>>(preburn_address).requests[0].value);
        ensures result == old(global<Preburn<Token>>(preburn_address).requests[0]);
    }

    // Publish `preburn` under the sender's account
    public fun publish_preburn<Token>(preburn: Preburn<Token>) {
        move_to_sender(preburn)
    }
    spec fun publish_preburn {
        aborts_if exists<Preburn<Token>>(sender());
        ensures exists<Preburn<Token>>(sender());
        ensures global<Preburn<Token>>(sender()) == preburn;
    }

    // Remove and return the `Preburn` resource under the sender's account
    public fun remove_preburn<Token>(): Preburn<Token> acquires Preburn {
        move_from<Preburn<Token>>(Transaction::sender())
    }
    spec fun remove_preburn {
        aborts_if !exists<Preburn<Token>>(sender());
        ensures !exists<Preburn<Token>>(sender());
        ensures result == old(global<Preburn<Token>>(sender()));
    }

    // Destroys the given preburn resource.
    // Aborts if `requests` is non-empty
    public fun destroy_preburn<Token>(preburn: Preburn<Token>) {
        let Preburn { requests, is_approved: _ } = preburn;
        Vector::destroy_empty(requests)
    }
    spec fun destroy_preburn {
        aborts_if len(preburn.requests) > 0;
    }

    // Publish `capability` under the sender's account
    public fun publish_mint_capability<Token>(capability: MintCapability<Token>) {
        move_to_sender(capability)
    }
    spec fun publish_mint_capability {
        aborts_if exists<MintCapability<Token>>(sender());
        ensures exists<MintCapability<Token>>(sender());
        ensures capability == global<MintCapability<Token>>(sender());
    }

    // Remove and return the MintCapability from the sender's account. Fails if the sender does
    // not have a published MintCapability
    public fun remove_mint_capability<Token>(): MintCapability<Token> acquires MintCapability {
        move_from<MintCapability<Token>>(Transaction::sender())
    }
    spec fun remove_mint_capability {
        aborts_if !exists<MintCapability<Token>>(sender());
        ensures !exists<MintCapability<Token>>(sender());
        ensures result == old(global<MintCapability<Token>>(sender()));
    }

    // Return the total value of all Libra in the system
    public fun market_cap<Token>(): u128 acquires Info {
        borrow_global<Info<Token>>(0xA550C18).total_value
    }
    spec fun market_cap {
        aborts_if !exists<Info<Token>>(0xA550C18);
        ensures result == global<Info<Token>>(0xA550C18).total_value;
    }

    // Return the total value of Libra to be burned
    public fun preburn_value<Token>(): u64 acquires Info {
        borrow_global<Info<Token>>(0xA550C18).preburn_value
    }
    spec fun preburn_value {
        aborts_if !exists<Info<Token>>(0xA550C18);
        ensures result == global<Info<Token>>(0xA550C18).preburn_value;
    }

    // Create a new Libra::T with a value of 0
    public fun zero<Token>(): T<Token> {
        // prevent silly coin types (e.g., Libra<bool>) from being created
        assert_is_registered<Token>();
        T { value: 0 }
    }
    spec fun zero {
        aborts_if !exists<Info<Token>>(0xA550C18);
        ensures result.value == 0;
    }

    // Public accessor for the value of a coin
    public fun value<Token>(coin_ref: &T<Token>): u64 {
        coin_ref.value
    }
    spec fun value {
        ensures result == coin_ref.value;
    }

    // Splits the given coin into two and returns them both
    // It leverages `withdraw` for any verifications of the values
    public fun split<Token>(coin: T<Token>, amount: u64): (T<Token>, T<Token>) {
        let other = withdraw(&mut coin, amount);
        (coin, other)
    }
    spec fun split {
        aborts_if coin.value < amount;
        ensures result_1.value == coin.value - amount;
        ensures result_2.value == amount;
    }

    // "Divides" the given coin into two, where original coin is modified in place
    // The original coin will have value = original value - `value`
    // The new coin will have a value = `value`
    // Fails if the coins value is less than `value`
    public fun withdraw<Token>(coin_ref: &mut T<Token>, value: u64): T<Token> {
        // Check that `amount` is less than the coin's value
        assert(coin_ref.value >= value, 10);

        // Split the coin
        coin_ref.value = coin_ref.value - value;
        T { value }
    }
    spec fun withdraw {
        aborts_if coin_ref.value < value;
        ensures coin_ref.value == old(coin_ref.value) - value;
        ensures result.value == value;
    }

    // Merges two coins and returns a new coin whose value is equal to the sum of the two inputs
    public fun join<Token>(coin1: T<Token>, coin2: T<Token>): T<Token>  {
        deposit(&mut coin1, coin2);
        coin1
    }
    spec fun join {
        aborts_if coin1.value + coin2.value > max_u64();
        ensures result.value == coin1.value + coin2.value;
    }

    // "Merges" the two coins
    // The coin passed in by reference will have a value equal to the sum of the two coins
    // The `check` coin is consumed in the process
    public fun deposit<Token>(coin_ref: &mut T<Token>, check: T<Token>) {
        let T { value } = check;
        coin_ref.value= coin_ref.value + value;
    }
    spec fun deposit {
        aborts_if coin_ref.value + check.value > max_u64();
        ensures coin_ref.value == old(coin_ref.value) + check.value;
    }

    // Destroy a coin
    // Fails if the value is non-zero
    // The amount of Libra::T in the system is a tightly controlled property,
    // so you cannot "burn" any non-zero amount of Libra::T
    public fun destroy_zero<Token>(coin: T<Token>) {
        let T<Token> { value } = coin;
        assert(value == 0, 11);
    }
    spec fun destroy_zero {
        aborts_if coin.value > 0;
    }
}
}
