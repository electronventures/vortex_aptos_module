module dev::vortex {
    use std::timestamp;
    use std::signer;
    use std::vector;
    use std::simple_map::{SimpleMap, Self};
    use aptos_framework::coin;
    use aptos_framework::aptos_coin;
    use aptos_framework::randomness;

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account::create_account;
    #[test_only]
    use aptos_framework::aptos_coin::initialize_for_test;
    #[test_only]
    use aptos_framework::resource_account;
    #[test_only]
    use std::debug;
    #[test_only]
    use aptos_std::crypto_algebra::enable_cryptography_algebra_natives;

    //:!:>resource
    struct GameStatus has store, key, copy, drop {
        round: u64,
        lastRoundTime: u64,
        roundToPlayerEntryMap: SimpleMap<u64, vector<PlayerEntry>>,
        addressToUnclaimedTokenMap: SimpleMap<address, u64>
    }

    struct PlayerEntry has store, copy, drop {
        entry: u64,
        entryTime: u64,
        player: address
    }

    struct VortexVault has key {
        coins: coin::Coin<aptos_coin::AptosCoin>
    }

    struct CurrentGameStatus has drop {
        round: u64,
        lastRoundTime: u64,
        players: u64,
        prize: u64,
        entryList: vector<PlayerEntry>
    }

    //<:!:resource

    #[event]
    struct NewRound has drop, store {
        round: u64
    }

    #[event]
    struct EnterGame has drop, store {
        playerAddress: address,
        entry: u64,
        rounds: u64,
        startRound: u64
    }

    #[event]
    struct StartGame has drop, store {
        startAddress: address,
        currentRound: u64
    }

    #[event]
    struct TriggerStartGame has drop, store {
        startAddress: address,
        currentRound: u64
    }

    #[event]
    struct Winner has drop, store {
        winnerAddress: address,
        currentRound: u64,
        prize: u64,
        playerCount: u64,
        playerEntry: u64
    }

    #[event]
    struct NoWinner has drop, store {
        currentRound: u64,
        prize: u64,
        playerCount: u64
    }

    #[event]
    struct ClaimPrize has drop, store {
        claimAddress: address,
        value: u64
    }

    #[event]
    struct UpdateLastRoundTime has drop, store {
        time: u64
    }

    #[event]
    struct PlayerRoundEntry has drop, store {
        playerAddress: address,
        entry: u64,
        currentRound: u64
    }

    // There is no message present
    const MODULE_NOT_EXIST: u64 = 0;
    const NO_UNCLAIMED_PRIZE: u64 = 1;
    const GAME_DURATION_TOO_SHORT: u64 = 2;

    const FixedGameDuration: u64 = 90;
    const PlatformFeePercentage: u64 = 1;

    entry fun init_module(sender: &signer) {
        // NOTE: Initializes the vault...
        if (!exists<VortexVault>(@dev)) {
            let initialCoins = coin::zero<aptos_coin::AptosCoin>();
            move_to(sender, VortexVault { coins: initialCoins });
        };

        let roundToPlayerEntryMap = simple_map::create<u64, vector<PlayerEntry>>();
        simple_map::add(&mut roundToPlayerEntryMap, 0, vector::empty<PlayerEntry>());

        // let now = timestamp::now_seconds();
        let now = 0;
        let gameStatus = GameStatus {
            round: 0,
            lastRoundTime: now,
            roundToPlayerEntryMap: roundToPlayerEntryMap,
            addressToUnclaimedTokenMap: simple_map::create<address, u64>()
        };
        move_to(sender, gameStatus);
    }

    #[randomness]
    entry fun start_game(sender: &signer) acquires GameStatus {
        let currentRoundPrize = get_current_round_prize();
        let currentRoundPlayer = get_current_round_player();

        let gs = borrow_global_mut<GameStatus>(@dev);
        let round = gs.round;

        let lastRoundTime = gs.lastRoundTime;
        let now = timestamp::now_seconds();
        assert!(now > lastRoundTime + 90, GAME_DURATION_TOO_SHORT);

        let address = signer::address_of(sender);
        let startGameEvent = StartGame { startAddress: address, currentRound: round };
        0x1::event::emit(startGameEvent);

        let roundToPlayerEntryMap = &mut gs.roundToPlayerEntryMap;
        let addressToUnclaimedTokenMap = &mut gs.addressToUnclaimedTokenMap;
        let playerExist = simple_map::contains_key(roundToPlayerEntryMap, &round);

        if (playerExist) {
            let playerEntryList: &mut vector<PlayerEntry> =
                simple_map::borrow_mut(roundToPlayerEntryMap, &round);

            for (playerIndex in 0..currentRoundPlayer) {
                let item: &PlayerEntry = vector::borrow(playerEntryList, playerIndex);
                let playerRoundEntryEvent = PlayerRoundEntry {
                    playerAddress: item.player,
                    entry: item.entry,
                    currentRound: round
                };
                0x1::event::emit(playerRoundEntryEvent);
            };

            if (currentRoundPlayer > 1) {
                let winnerNumber = decide_winner(currentRoundPrize) + 1;
                let winnerIndex = 0;

                while (winnerNumber > 0) {
                    let element = vector::borrow(playerEntryList, winnerIndex);
                    if (element.entry >= winnerNumber) { break };
                    winnerNumber = winnerNumber - element.entry;
                    winnerIndex = winnerIndex + 1;
                };
                let winner = vector::borrow(playerEntryList, winnerIndex);

                let keyExist =
                    simple_map::contains_key(addressToUnclaimedTokenMap, &winner.player);
                if (!keyExist) {
                    simple_map::add(
                        addressToUnclaimedTokenMap, winner.player, currentRoundPrize
                    );
                } else {
                    let unclaimed_prize =
                        simple_map::borrow_mut(addressToUnclaimedTokenMap, &winner.player);
                    *unclaimed_prize = *unclaimed_prize + currentRoundPrize;
                };

                let winnerEvent = Winner {
                    winnerAddress: winner.player,
                    currentRound: round,
                    prize: currentRoundPrize,
                    playerCount: currentRoundPlayer,
                    playerEntry: winner.entry
                };
                0x1::event::emit(winnerEvent);
            };
            if (currentRoundPlayer == 1) {
                let element = vector::remove(playerEntryList, 0);

                let keyExist =
                    simple_map::contains_key(roundToPlayerEntryMap, &(gs.round + 1));
                if (keyExist) {
                    let nextRoundPlayerEntryList =
                        simple_map::borrow_mut(roundToPlayerEntryMap, &(gs.round + 1));
                    let length = vector::length(nextRoundPlayerEntryList);
                    let found = false;

                    for (playerIndex in 0..length) {
                        let item: &mut PlayerEntry = vector::borrow_mut(
                            nextRoundPlayerEntryList, playerIndex
                        );
                        if (item.player == element.player) {
                            found = true;
                            item.entry = item.entry + element.entry;
                            break
                        }
                    };

                    if (!found) {
                        vector::push_back(
                            nextRoundPlayerEntryList,
                            element
                        );
                    };
                } else {
                    let nextRoundPlayerEntryList: vector<PlayerEntry> = vector::empty<
                        PlayerEntry>();
                    vector::push_back(
                        &mut nextRoundPlayerEntryList,
                        element
                    );
                    simple_map::add(
                        roundToPlayerEntryMap, round + 1, nextRoundPlayerEntryList
                    );
                };

                let noWinnerEvent = NoWinner {
                    currentRound: round,
                    playerCount: 1,
                    prize: element.entry
                };
                0x1::event::emit(noWinnerEvent);
            };
            if (currentRoundPlayer == 0) {
                let noWinnerEvent = NoWinner {
                    currentRound: round,
                    playerCount: 0,
                    prize: 0
                };
                0x1::event::emit(noWinnerEvent);
            }
        } else {
            let noWinnerEvent = NoWinner { currentRound: round, playerCount: 0, prize: 0 };
            0x1::event::emit(noWinnerEvent);
        };

        update_game_state();
    }

    fun decide_winner(currentRoundPrize: u64): u64 {
        randomness::u64_range(0, currentRoundPrize)
    }

    entry fun claim_prize(sender: &signer) acquires GameStatus, VortexVault {
        let address = signer::address_of(sender);
        let unclaimedPrize = get_unclaimed_prize(address);
        assert!(unclaimedPrize != 0, NO_UNCLAIMED_PRIZE);

        let vault = borrow_global_mut<VortexVault>(@dev);
        let withdrawnCoins =
            coin::extract<aptos_coin::AptosCoin>(&mut vault.coins, unclaimedPrize);
        coin::deposit<aptos_coin::AptosCoin>(address, withdrawnCoins);

        let gs = borrow_global_mut<GameStatus>(@dev);
        let addressToUnclaimedTokenMap = &mut gs.addressToUnclaimedTokenMap;
        simple_map::remove(addressToUnclaimedTokenMap, &address);

        let claimPrizeEvent = ClaimPrize { claimAddress: address, value: unclaimedPrize };
        0x1::event::emit(claimPrizeEvent);
    }

    entry fun enter_game(sender: &signer, round: u64, amount: u64) acquires GameStatus, VortexVault {
        let address = signer::address_of(sender);

        let vault = borrow_global_mut<VortexVault>(@dev);
        let coins = coin::withdraw<aptos_coin::AptosCoin>(sender, round * amount);
        coin::merge(&mut vault.coins, coins);

        let gs = borrow_global_mut<GameStatus>(@dev);
        let currentRound = gs.round;
        let roundToPlayerEntryMap = &mut gs.roundToPlayerEntryMap;

        for (index in currentRound..(currentRound + round)) //range -> from 1 to n
        {
            let keyExist = simple_map::contains_key(roundToPlayerEntryMap, &index);

            // NOTE: first entry for the target round...
            if (!keyExist) {
                let playerEntryList: vector<PlayerEntry> = vector::empty<PlayerEntry>();
                let now = timestamp::now_seconds();
                vector::push_back(
                    &mut playerEntryList,
                    PlayerEntry { player: address, entry: amount, entryTime: now }
                );
                simple_map::add(roundToPlayerEntryMap, index, playerEntryList);
                continue
            };

            let found = false;
            let playerEntryList: &mut vector<PlayerEntry> =
                simple_map::borrow_mut(roundToPlayerEntryMap, &index);
            let length = vector::length(playerEntryList);

            for (playerIndex in 0..length) {
                let item: &mut PlayerEntry = vector::borrow_mut(
                    playerEntryList, playerIndex
                );
                if (item.player == address) {
                    found = true;
                    item.entry = item.entry + amount;
                    break
                }
            };

            if (found) continue;

            let now = timestamp::now_seconds();
            vector::push_back(
                playerEntryList,
                PlayerEntry { player: address, entry: amount, entryTime: now }
            );
        };

        let enterGameEvent = EnterGame {
            playerAddress: address,
            entry: amount,
            rounds: round,
            startRound: currentRound
        };
        0x1::event::emit(enterGameEvent);
    }

    fun update_game_state() acquires GameStatus {
        assert!(exists<GameStatus>(@dev), MODULE_NOT_EXIST);
        let gs = borrow_global_mut<GameStatus>(@dev);
        let round = &mut gs.round;
        let lastRoundTime = &mut gs.lastRoundTime;
        let roundToPlayerEntryMap = &mut gs.roundToPlayerEntryMap;

        let now = timestamp::now_seconds();

        let keyExist = simple_map::contains_key(roundToPlayerEntryMap, round);
        if (keyExist) {
            simple_map::remove(roundToPlayerEntryMap, round);
        };
        *round = *round + 1;
        *lastRoundTime = now;

        let newRoundEvent = NewRound { round: *round };
        let updateLastRoundTimeEvent = UpdateLastRoundTime { time: now };
        0x1::event::emit(newRoundEvent);
        0x1::event::emit(updateLastRoundTimeEvent);
    }

    // ========== VIEW ==========

    #[view]
    public fun view_vault_balance(): u64 acquires VortexVault {
        assert!(exists<VortexVault>(@dev), MODULE_NOT_EXIST);
        let vault = borrow_global<VortexVault>(@dev);
        coin::value<aptos_coin::AptosCoin>(&vault.coins)
    }

    #[view]
    public fun get_game_status(): GameStatus acquires GameStatus {
        assert!(exists<GameStatus>(@dev), MODULE_NOT_EXIST);
        let gs = borrow_global<GameStatus>(@dev);
        return *gs
    }

    #[view]
    public fun get_last_round_time(): u64 acquires GameStatus {
        assert!(exists<VortexVault>(@dev), MODULE_NOT_EXIST);
        let gs = borrow_global<GameStatus>(@dev);
        return gs.lastRoundTime
    }

    #[view]
    public fun get_unclaimed_prize(addr: address): u64 acquires GameStatus {
        assert!(exists<GameStatus>(@dev), MODULE_NOT_EXIST);
        let gs = borrow_global<GameStatus>(@dev);
        let addressToUnclaimedTokenMap = gs.addressToUnclaimedTokenMap;
        let keyExist = simple_map::contains_key(&addressToUnclaimedTokenMap, &addr);
        if (!keyExist) return 0;
        let unclaimed = simple_map::borrow(&addressToUnclaimedTokenMap, &addr);
        return *unclaimed
    }

    #[view]
    public fun get_current_round_player(): u64 acquires GameStatus {
        assert!(exists<GameStatus>(@dev), MODULE_NOT_EXIST);
        let gs = borrow_global<GameStatus>(@dev);
        let round = gs.round;
        let roundToPlayerEntryMap = gs.roundToPlayerEntryMap;
        let keyExist = simple_map::contains_key(&roundToPlayerEntryMap, &round);
        if (!keyExist) return 0;
        let playerEntryList: &vector<PlayerEntry> =
            simple_map::borrow(&roundToPlayerEntryMap, &round);
        return vector::length(playerEntryList)
    }

    #[view]
    public fun get_current_round_prize(): u64 acquires GameStatus {
        assert!(exists<GameStatus>(@dev), MODULE_NOT_EXIST);
        let gs = borrow_global<GameStatus>(@dev);
        let round = gs.round;
        let roundToPlayerEntryMap = gs.roundToPlayerEntryMap;
        let keyExist = simple_map::contains_key(&roundToPlayerEntryMap, &round);
        if (!keyExist) return 0;
        let playerEntryList: &vector<PlayerEntry> =
            simple_map::borrow(&roundToPlayerEntryMap, &round);
        let playerCount = vector::length(playerEntryList);
        let prize = 0;
        let index = 0;
        while (index < playerCount) {
            let element = vector::borrow(playerEntryList, index);
            prize = prize + element.entry;
            index = index + 1;
        };
        return prize
    }

    #[view]
    public fun get_current_game_status(): CurrentGameStatus acquires GameStatus {
        assert!(exists<GameStatus>(@dev), MODULE_NOT_EXIST);

        let gs = borrow_global<GameStatus>(@dev);
        let round = gs.round;
        let lastRoundTime = gs.lastRoundTime;

        let roundToPlayerEntryMap = gs.roundToPlayerEntryMap;
        let keyExist = simple_map::contains_key(&roundToPlayerEntryMap, &round);
        let entryList: &vector<PlayerEntry> =
            if (keyExist) simple_map::borrow(&roundToPlayerEntryMap, &round)
            else &vector::empty<PlayerEntry>();

        let players = get_current_round_player();
        let prize = get_current_round_prize();

        return CurrentGameStatus {
            round: copy round,
            lastRoundTime: lastRoundTime,
            players: players,
            prize: prize,
            entryList: *entryList
        }
    }

    // ========== TEST ==========

    #[test]
    public entry fun init_test() acquires GameStatus {
        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        let gs = get_game_status();
        assert!(gs.round == 0, 10);
        assert!(gs.lastRoundTime == 0, 11);
        assert!(simple_map::length(&gs.roundToPlayerEntryMap) == 1, 12);
        assert!(simple_map::length(&gs.addressToUnclaimedTokenMap) == 0, 13);
    }

    #[test]
    public entry fun zero_unclaimed_test() acquires GameStatus {
        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        let unclaimed = get_unclaimed_prize(address);
        assert!(unclaimed == 0, 10);
    }

    #[test]
    public entry fun get_current_game_status_test() acquires GameStatus {
        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        let current_game_status = get_current_game_status();
        // debug::print(&current_game_status);
        assert!(current_game_status.round == 0, 10);
        assert!(current_game_status.players == 0, 11);
        assert!(current_game_status.prize == 0, 12);
    }

    #[test]
    public entry fun current_round_player_test() acquires GameStatus {
        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        let player_count = get_current_round_player();
        assert!(player_count == 0, 10);
    }

    #[test]
    public entry fun get_current_round_prize_test() acquires GameStatus {
        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        let prize = get_current_round_prize();
        assert!(prize == 0, 10);
    }

    #[test(framework = @0x1)]
    public entry fun start_game_test(framework: signer) acquires GameStatus {
        enable_cryptography_algebra_natives(&framework);
        randomness::initialize_for_testing(&framework);

        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        timestamp::set_time_has_started_for_testing(&framework);
        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        start_game(&account);
        let gs = get_game_status();
        assert!(gs.round == 1, 10);
    }

    #[test(framework = @0x1, user = @0xaaaa)]
    public entry fun enter_game_test(framework: signer, user: signer) acquires GameStatus, VortexVault {
        enable_cryptography_algebra_natives(&framework);
        randomness::initialize_for_testing(&framework);

        let account = account::create_signer_for_test(@dev);
        let address = signer::address_of(&account);

        timestamp::set_time_has_started_for_testing(&framework);
        init_module(&account);
        assert!(exists<GameStatus>(address), MODULE_NOT_EXIST);

        let (burn, mint) = initialize_for_test(&framework);
        let coinsForAdmin = coin::mint<aptos_coin::AptosCoin>(1000000, &mint);
        let coinsForUser = coin::mint<aptos_coin::AptosCoin>(1000000, &mint);

        create_account(signer::address_of(&account));
        resource_account::create_resource_account(
            &account, vector::empty(), vector::empty()
        );
        create_account(signer::address_of(&user));
        resource_account::create_resource_account(
            &user, vector::empty(), vector::empty()
        );

        coin::deposit(signer::address_of(&account), coinsForAdmin);
        coin::deposit(signer::address_of(&user), coinsForUser);

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        enter_game(&account, 1, 100);
        enter_game(&account, 2, 200);
        enter_game(&account, 3, 300);
        enter_game(&user, 4, 50);

        let balance = view_vault_balance();
        assert!(balance == 1600, 1);

        start_game(&account);
        claim_prize(&account);

        balance = view_vault_balance();
        assert!(balance == 950, 1);
    }
}
