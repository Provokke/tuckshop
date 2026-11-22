<div align="center">

# tuckshop

Currencies, a rotating shop and idempotent developer-product receipts for Roblox. It leaves out item art and any gameplay that uses what a player buys: a bought item is kept as a count in the player's saved data and shown as an attribute on the player. Player data is saved with a session lease, the same store as [satchel](https://github.com/Provokke/satchel).

![License](https://img.shields.io/badge/LICENSE-MIT-blue?style=for-the-badge)  ![Language](https://img.shields.io/badge/LUAU-00A2FF?style=for-the-badge&logo=roblox&logoColor=white)  ![Tests](https://img.shields.io/badge/TESTS-156-brightgreen?style=for-the-badge)

Refer to [LICENSE](LICENSE) for the legal bits.

</div>

## What's in it

- **Receipts that never grant twice and never lose a paid grant.** A developer-product purchase is granted, its `PurchaseId` is recorded in the player's data, and then the data is saved. Roblox is only told `PurchaseGranted` once that save has landed with this session's lease. If the save fails, the answer is `NotProcessedYet`, and the retry finds the id already recorded and only saves again. A retry on another server after the player's data was released reads the recorded id and doesn't grant again. A receipt that arrives as the player joins waits (up to 30 seconds) for their data to load instead of being turned away.
- **Grants fail safely.** A grant that errors or returns false records nothing and answers `NotProcessedYet`, and a refused one is logged with its purchase id so it can be refunded by hand. An unknown product, a player with no session, and a session that is read-only or has lost its lease all answer `NotProcessedYet` too, so nothing is ever granted on a guess or into data that won't be saved. Two calls for the same new `PurchaseId` at once grant once. The server script assigns a holding `ProcessReceipt` before anything else, so a start-up that stops early (a config problem, a module that fails to load) leaves purchases for Roblox to retry rather than letting them be acknowledged with nothing granted.
- **Session-locked data.** Each load claims the player's record with a lease belonging to that one session, so two servers can't both write it. Saves build their payload inside the `UpdateAsync` transform and queue per session, so an older save can't overwrite a newer one. A release keeps retrying through an outage. Records saved by a newer version of the game load read-only: the player can look at the shop but can't buy, be credited or have a receipt processed on that server.
- **A ledger with whole numbers only.** Every change to a balance goes through one function that refuses a non-integer, an unknown currency, an overdraw and an overflow, leaves the balance alone when it refuses, and logs the rest (the newest 25 entries by default).
- **A rotating shop that every server agrees on.** The listing is worked out from the wall clock: items marked `always` are always listed, and each pool lists its configured number of items, picked without replacement with a small seeded generator written in the module, so the same time gives the same shop on every server and in the tests.
- **Purchases the client can't price, saved with what they bought.** The server reads the price from the catalogue. A purchase checks the item is listed now, checks the per-window limit, then debits. The charge, the per-window allowance and the item itself (a count in the player's data) are written together with no yield between them, so the next save carries all three or none, and the items are given back to the player on every load. If handing the item over fails, all three are put back and the log shows the debit and the refund.
- **Game passes and a coin pad.** Pass ownership is cached per player. A failed check counts as not owned and is tried again every 30 seconds for 3 minutes while the player is here. A finished purchase counts straight away and is then checked with the server, which takes it back if the pass isn't owned. The `DoubleCoins` perk doubles the demo coin pad's reward and nothing else.
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
  ProcessReceipt)                               |    ---->  Profile (wallet, bought, owned, receipts)
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

- **init.server.luau** is the only server file that touches Players, DataStoreService, MarketplaceService and remotes. Its first statement assigns a holding `MarketplaceService.ProcessReceipt` that answers `NotProcessedYet`. It then builds everything with its dependencies, replaces that callback with the real one, and runs the coin pad and the autosave and shutdown loops.
- **Sessions.luau** is the session lifecycle on one server: load on join, release on leave, autosave and the shutdown wait. It says which sessions may be changed, and lets a receipt wait for a session that is still loading.
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

156 tests, all passing:

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
- Profile (5): starting balances written once by the first claim, every field kept through encode and decode, a currency added later, refused data with no wallet, and owned items filled in for older records.
- Sessions (9): a quick rejoin waiting for the old release, a rejoin during a slow load, loads stopping when the player leaves, shutdown within its timeout, read-only and lost sessions, a read-only session never written back, and a receipt waiting for a load: granted once it lands, refused when the player leaves, the load never lands or the session is read-only.
- Ledger (7): credits, debits, an overdraw leaving the balance alone, non-integer and unknown-currency refusals, log trimming and the overflow limit.
- Rotation (5): the same window gives the same listing, literal expected listings for three windows, the countdown, exact slot counts with no duplicates, and `always` items.
- Shop (9): a purchase debits, grants and keeps the item in the same data, unlisted items cost nothing, limits per window, not affording an item, refunds after a failed or throwing grant (charge, allowance and item all put back), the catalogue price being the only price, items counted per player, and a server whose clock is behind refused against a later window's allowance.
- Receipts (19): a first receipt, repeats, failing and throwing saves, no session, read-only and lost sessions, unknown products, failing grants, a refused grant logged with its purchase id, memory trimming, an unsaved id never trimmed, a retry on another server after the first server's save failed, a retry after it crashed, a save that lands and then errors, a receipt behind a parked autosave or a release, two calls interleaving across a slow save, and a slow grant started twice.
- Passes (7): owned and not owned, the placeholder id never checked, a failed check retried 30 seconds later without another refresh, retries that stop after six or when the player leaves, a check still running at leave not written back, a finished purchase counting at once, and a finished purchase taken back when the server says the pass isn't owned.
- Handlers (6): a buy request, malformed requests, the rate limit, a view-only session, a player with no session, and the listing sent to the client.
- Server script (8): the real `init.server.luau`, run over a small stand-in for the Roblox services it uses (`tests/fakes/FakeGame.luau`). A bad config, a module that fails to load and a `WaitForChild` that never returns all leave a callback that answers `NotProcessedYet`; a receipt during a slow load is granted once it lands; a bought item is saved with its charge and restored on rejoin; the coin pad and a pass the server confirms; a pass check retried after a failure at join; a failed Sync after a saved receipt; and a refused grant logged.

The client script and the UI can't run under Lune. They build with Rojo and are checked in Studio. The stand-in the server script runs on models only the members it uses, and a call to anything else fails the test, but it is not Roblox: timing, replication and the real services are checked in Studio. The runner counts a test that yields and never finishes as a failure, so a hung test can't end the run with no output.

## ⚠️ Honest limits

- Developer products and game passes need your own ids. The placeholder `0` in `Config.luau` does nothing, and nothing in this repo has been bought with real Robux.
- Rotation is by wall clock (`os.time`), so a server whose clock drifts shows the next shop early or late by the drift. Two servers can also disagree by a second or two around a window change. A player who moves to a server that is behind, just after a change, can't buy an item they already bought in the new window until that server catches up, so a limit can't be used twice.
- The receipt memory is a capped list (200 by default). A retry that arrives after its id has been dropped would be granted again. A server never drops an id it recorded until a save carrying it has landed, so a receipt waiting on this server for its retry is safe however many newer ones arrive (the list runs over the cap until then). What is left is a retry that comes more than `ReceiptMemory` purchases late: one Roblox redelivers after it was told `PurchaseGranted`, or one still unanswered after the player moved server, since the new server only knows the id as saved data. Roblox redelivers pending receipts at the player's next purchase or join, long before that. If two receipts land in the same second at the memory limit, the one dropped is picked by id, not by order.
- A grant that returns false must have changed nothing. A grant that changes data and then fails would be changed again on the retry.
- Receipts only count as granted once the data is saved. If the server crashes after granting but before the save, the player's stored data has no grant, and the retry grants it once more from the stored copy. That is the point of the order, but it means a grant that has effects outside the player's data (a message, a Robux gift) can happen twice.
- Balances are whole numbers only, and a balance is capped at 2^53 - 1.
- A bought item is a count in the player's data (`owned`), saved with its charge. The demo shows it as an `Owns_<itemId>` attribute on the player and nothing in the demo uses it. A game puts its own hand-over (a Tool, a cosmetic) in `itemGranted` and in the restore on load, both in the server script.
- If the DataStore stays down for longer than the lease (3 minutes by default) after a player leaves, the release gives up and what they did since the last successful save is lost. Until the release lands or the lease runs out, a rejoin on another server is turned away with "rejoin in a minute".
- During a rolling update, a player whose record was saved by the newer version can look at the shop on an older server, but can't buy, earn from the coin pad or have a receipt processed there. Roblox retries the receipt on a server that can.
- A receipt that arrives before the player's data has loaded waits up to 30 seconds. If the load takes longer (a long outage, or another server still holding the record), the answer is `NotProcessedYet`, and Roblox only asks again at the player's next purchase or rejoin. When Roblox calls `ProcessReceipt` relative to a join is not documented, and this hasn't been measured with real purchases.
- A finished game-pass purchase is checked with `UserOwnsGamePassAsync` in the background and taken back if that says the pass isn't owned. This relies on Roblox's statement that the finished event updates the cache the check reads, which hasn't been tried with a real purchase. A check that errors keeps the purchase.
- In Studio the demo uses an in-memory store unless the `TuckshopUseDataStore` attribute is set, so it proves the flow but not real DataStore behaviour such as throttling. The Lune fake does model re-runs, interleaved calls and calls that fail after writing. What the request budget reads in Studio with the real store and no API access hasn't been checked.
- The UI is functional rather than finished: no gamepad support, no item art and a fixed layout.

## Licence

MIT.
