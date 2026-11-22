<div align="center">

# tuckshop

Currencies, a rotating shop and idempotent developer-product receipts for Roblox. It leaves out item art, inventories and any gameplay that uses what a player buys. Player data is saved with a session lease, the same store as [satchel](https://github.com/Provokke/satchel).

![License](https://img.shields.io/badge/LICENSE-MIT-blue?style=for-the-badge)  ![Language](https://img.shields.io/badge/LUAU-00A2FF?style=for-the-badge&logo=roblox&logoColor=white)  ![Tests](https://img.shields.io/badge/TESTS-137-brightgreen?style=for-the-badge)

Refer to [LICENSE](LICENSE) for the legal bits.

</div>

## What's in it

- **Receipts that never grant twice and never lose a paid grant.** A developer-product purchase is granted, its `PurchaseId` is recorded in the player's data, and then the data is saved. Roblox is only told `PurchaseGranted` once that save has landed with this session's lease. If the save fails, the answer is `NotProcessedYet`, and the retry finds the id already recorded and only saves again. A retry on another server after the player's data was released reads the recorded id and doesn't grant again.
- **Grants fail safely.** A grant that errors or returns false records nothing and answers `NotProcessedYet`. An unknown product, a player with no session, and a session that is read-only or has lost its lease all answer `NotProcessedYet` too, so nothing is ever granted on a guess or into data that won't be saved. Two calls for the same new `PurchaseId` at once grant once.
- **Session-locked data.** Each load claims the player's record with a lease belonging to that one session, so two servers can't both write it. Saves build their payload inside the `UpdateAsync` transform and queue per session, so an older save can't overwrite a newer one. A release keeps retrying through an outage. Records saved by a newer version of the game load read-only: the player can look at the shop but can't buy, be credited or have a receipt processed on that server.
- **A ledger with whole numbers only.** Every change to a balance goes through one function that refuses a non-integer, an unknown currency, an overdraw and an overflow, leaves the balance alone when it refuses, and logs the rest (the newest 25 entries by default).
- **A rotating shop that every server agrees on.** The listing is worked out from the wall clock: items marked `always` are always listed, and each pool lists its configured number of items, picked without replacement with a small seeded generator written in the module, so the same time gives the same shop on every server and in the tests.
- **Purchases the client can't price.** The server reads the price from the catalogue. A purchase checks the item is listed now, checks the per-window limit, then debits. If handing the item over fails, the charge is refunded and the log shows both.
- **Game passes and a coin pad.** Pass ownership is cached per player, a failed check counts as not owned and is retried on the next refresh, and a finished purchase counts straight away. The `DoubleCoins` perk doubles the demo coin pad's reward and nothing else.
- **Server authority.** Clients send intent only (`buy` with an item id, or `listing`). Every call is checked for type and range, rate limited per player and then checked against the rules. A refused call is dropped and counted, and nothing is sent back about why.

```lua
-- src/shared/Config.luau
Products = table.freeze({
	[1234567890] = table.freeze({ grant = "Gems", amount = 100 }), -- your developer product id
}),
GamePasses = table.freeze({
	[987654321] = table.freeze({ perk = "DoubleCoins" }), -- your game pass id
}),
```

## 🏗️ Architecture

```
                     Player joins / leaves / autosave / shutdown
                                   |
                                   v
 init.server.luau  ------->  Sessions  ---->  Store  ---->  Lease (claim / refresh / release)
 (services, remotes,                            |    ---->  Migrations + Steps
  ProcessReceipt)                               |    ---->  Profile (wallet, bought, receipts)
        |                                       v
        |                                  DataStore  (MemoryStore in Studio)
        |
        |  ProcessReceipt ------> Receipts ---> session.data.receipts, session:save()
        |
        |  Request (RemoteEvent)           Sync (RemoteEvent)
        |  <---------------------------    --------------------------->
        v                                                            client
   Handlers  -- Validate, RateLimiter ---> Shop ---> Rotation (listing), Ledger (balances)
        |
        v
   Sync: balances, listing, seconds left
```

- **init.server.luau** is the only server file that touches Players, DataStoreService, MarketplaceService and remotes. It builds everything with its dependencies, assigns `MarketplaceService.ProcessReceipt` once, runs the coin pad and the autosave and shutdown loops.
- **Sessions.luau** is the session lifecycle on one server: load on join, release on leave, autosave and the shutdown wait. It says which sessions may be changed.
- **Data/Lease.luau**, **Data/Migrations.luau**, **Data/Steps.luau**, **Data/Store.luau** and **Data/MemoryStore.luau** are the session store, copied from satchel.
- **Data/Profile.luau** is what a new profile holds (the starting balances, so the first claim writes them) and how it is encoded for storage.
- **Shop/Ledger.luau** holds the balances and the log of changes.
- **Shop/Rotation.luau** works out the listing and the seconds until it changes.
- **Shop/Shop.luau** is a purchase: listed, under the limit, debit, hand over, refund on failure.
- **Shop/Receipts.luau** is the money path. The rules sit in a comment at the top of the file.
- **Shop/Passes.luau** caches game pass ownership.
- **Handlers.luau** validates and rate limits every client request and builds the Sync.
- **client/ShopWindow.luau** is the panel: tabs, cards, the countdown and the confirm dialogue. **client/init.client.luau** wires it up and counts the balances up and down.

## 🚀 Quick start

```
rokit install
rojo serve
```

Start from an empty baseplate, connect the Rojo plugin and press Play. Add a part, give it the tag `TuckshopCoinPad` and stand on it: you get 10 Coins each time, at most once every 3 seconds. Press the Shop button at the bottom left to open the shop. The Featured tab lists everything in stock, Skins and Boosts filter it, and the countdown shows when the stock changes. Choosing an item asks you to confirm and shows what you will have left. Without a coin pad part the server warns once and carries on.

To sell Gems, put your own developer product ids in `Products` in `Config.luau`. The entry `[0]` is a placeholder that nothing buys, and the Buy Gems tab shows only real ids. Game passes work the same way through `GamePasses`.

In Studio the server uses an in-memory store, so nothing is saved between sessions. To use the real DataStore, set the attribute `TuckshopUseDataStore` to true on ServerStorage and turn on API access for the place.

## 🧪 Testing

```
lune run tests/run
```

137 tests, all passing:

- Rate limiter (4): a full bucket allows exactly its capacity, time refills it, it never overfills, and forgetting a key resets only that key.
- Validate (10): integers, strings, unit vectors and set membership, including NaN, infinity, floats, wrong types and out-of-range values.
- Config checks (11): the shipped config passes, and each rule (currencies, whole-number prices, pools and their slot counts, receipt memory, products, schema version, lease length, retries, close timeout) fails when broken and passes when fixed.
- Lease (13): new, taken, stolen and held outcomes, expiry, refresh, release, lost leases, records with no lease, a release that already landed, and no mutation of the stored record.
- Migrations (5): steps run in order, current records are unchanged, records from the future go read-only, the input is never mutated, and a missing step names the schema.
- Fake data store (4): the fake re-runs transforms on fresh copies, re-runs when the record changes between read and write, can fail after writing, and cancels on nil.
- Store (11): fresh loads, two-server lockout, stealing an expired lease, load retries, persistent failure, the budget wait, read-only saves and releases, double release, round trips and the encode hooks.
- Store leases (8): two sessions on one server, the lease owner, a claim or release that landed but errored, long release outages with capped waits, and a release after another server took over.
- Store loads (8): records that can't be migrated or decoded hand the lease back, no wait after the last attempt, landed claims cleared after a failure or a call-off, budget readings that throw, and loads called off when the player leaves.
- Store saves (5): an older autosave can't land after a newer save, a budget wait or a re-run writes current data, a release queued behind a save, and every transform giving the same record when re-run.
- Memory store (2): copies on the way in and out, and the cancel-on-nil contract.
- Profile (5): starting balances written once by the first claim, every field kept through encode and decode, a currency added later, and refused data with no wallet.
- Sessions (7): a quick rejoin waiting for the old release, a rejoin during a slow load, loads stopping when the player leaves, shutdown within its timeout, read-only and lost sessions, and a read-only session never written back.
- Ledger (7): credits, debits, an overdraw leaving the balance alone, non-integer and unknown-currency refusals, log trimming and the overflow limit.
- Rotation (5): the same window gives the same listing, literal expected listings for three windows, the countdown, exact slot counts with no duplicates, and `always` items.
- Shop (7): a purchase debits and grants, unlisted items cost nothing, limits per window, not affording an item, refunds after a failed or throwing grant, and the catalogue price being the only price.
- Receipts (15): a first receipt, repeats, failing and throwing saves, no session, read-only and lost sessions, unknown products, failing grants, memory trimming, a retry on another server after the first server's save failed, a retry after it crashed, two calls interleaving across a slow save, and a slow grant started twice.
- Passes (4): owned and not owned, the placeholder id never checked, a failed check retried, and a finished purchase counting at once.
- Handlers (6): a buy request, malformed requests, the rate limit, a view-only session, a player with no session, and the listing sent to the client.

The entry scripts and the UI can't run under Lune. They build with Rojo and are checked in Studio. The server entry script is wiring only: the rules it starts live in modules that are tested. The runner counts a test that yields and never finishes as a failure, so a hung test can't end the run with no output.

## ⚠️ Honest limits

- Developer products and game passes need your own ids. The placeholder `0` in `Config.luau` does nothing, and nothing in this repo has been bought with real Robux.
- Rotation is by wall clock (`os.time`), so a server whose clock drifts shows the next shop early or late by the drift. Two servers can also disagree by a second or two around a window change.
- The receipt memory is a capped list (200 by default). A retry more than `ReceiptMemory` purchases after the original would be granted again. Roblox retries a receipt until it is granted, and this never leaves one ungranted past a successful save, so that only matters for a purchase that stays unanswered through that many newer ones. If two receipts land in the same second at the memory limit, the one dropped is picked by id, not by order.
- A grant that returns false must have changed nothing. A grant that changes data and then fails would be changed again on the retry.
- Receipts only count as granted once the data is saved. If the server crashes after granting but before the save, the player's stored data has no grant, and the retry grants it once more from the stored copy. That is the point of the order, but it means a grant that has effects outside the player's data (a message, a Robux gift) can happen twice.
- Balances are whole numbers only, and a balance is capped at 2^53 - 1.
- The demo hands over a bought item by counting it as an attribute on the player. That isn't saved. A real game replaces `itemGranted` in the server script with its own hand-over. Purchases per window are saved, but items are not.
- If the DataStore stays down for longer than the lease (3 minutes by default) after a player leaves, the release gives up and what they did since the last successful save is lost. Until the release lands or the lease runs out, a rejoin on another server is turned away with "rejoin in a minute".
- During a rolling update, a player whose record was saved by the newer version can look at the shop on an older server, but can't buy, earn from the coin pad or have a receipt processed there. Roblox retries the receipt on a server that can.
- In Studio the demo uses an in-memory store unless the `TuckshopUseDataStore` attribute is set, so it proves the flow but not real DataStore behaviour such as throttling. The Lune fake does model re-runs, interleaved calls and calls that fail after writing. What the request budget reads in Studio with the real store and no API access hasn't been checked.
- The UI is functional rather than finished: no gamepad support, no item art and a fixed layout.

## Licence

MIT.
