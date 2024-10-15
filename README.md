## Vortex Move Module

Vortex is deployed on the _Aptos testnet_. We utilize **Aptos randomness API** on Aptos testnet to help with our winner selection process.
Since the randomness is built into the chain, no additional oracles and  fees are required, resulting in a safe and rapid winner selection process.

### Structs

- **GameStatus**
  - **round**: the current round.
  - **lastRoundTime**: the timestamp when the last round completes.
  - **roundToPlayerEntryMap**: the map to keep track of player entries.
  - **addressToUnclaimedTokenMap**: the map to keep track of winners' unclaimed rewards.
  

- **PlayerEntry**
  - **entry**: the amount of APT the user sends.
  - **entryTime**: the timestamp when user enters the game.
  - **player**: the address of the user.
  

- **VortexVault**
  - **coins**: the amount of APT the module holds.


- **CurrentGameStatus**
    - **round**: the current round.
    - **lastRoundTime**: the timestamp when the last round completes.
    - **players**: player count of the current round.
    - **prize**: prize of the current round.
    - **entryList**: list of player entries of the current round.


### Entry functions

- ``enter_game(sender: &signer, round: u64, amount: u64)``
  - user call this function to enter the roulette game, specifying the rounds and entries.
- ``claim_prize(sender: &signer)``
  - user call this function to claim prizes they won in the game.
- ``start_game(sender: &signer)``
  - the function that triggers winner selection.
  - the function calls **decide_winner**, which uses the `randomness` module on the Aptos testnet as th main source of random number.
  - the function has a 90 seconds cooldown.

```move
fun decide_winner(currentRoundPrize: u64): u64 {
    randomness::u64_range(0, currentRoundPrize)
}
```

### View functions

- ``view_vault_balance()``: get the APT balance of the module.
- ``get_game_status()``: returns `GameStatus`.
- ``get_last_round_time()``: returns `lastRoundTime` in `GameStatus`.
- ``get_unclaimed_prize(address)``: returns the unclaimed prize of the given address.
- ``get_current_round_player()``: returns the player count of the current round.
- ``get_current_round_prize()``: returns the prize of the current round.
- ``get_current_game_status()``: returns `CurrentGameStatus`.
