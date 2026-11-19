# Morpheus bug bounty PoC — LumerinDiamond provider self-deal (Finding A)

Bug-bounty proof of concept for the Morpheus program (mor.org/bug-bounty).
A provider who is also the user opens a session against their own bid, serves
no inference, waits to `endsAt`, and claims from the funding account — there is
no on-chain proof of inference anywhere in the design. One session farmed
292 MOR (~$207) with the provider stake refunded in full.

Target: LumerinDiamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` (Base),
facets ProviderRegistry / ModelRegistry / Marketplace / Delegation / SessionRouter.

## Run (one command, from a clean clone)

```bash
forge test --fork-url https://base-rpc.publicnode.com --fork-block-number 59525351 -vvv
```

Fork is pinned to Base block **59525351** (2026-11-19). Read-only RPC; no
mainnet transactions, no funds spent. All tests use unprivileged EOAs
(`vm.addr` keys); the only "privileged" action is `deal` cheatcode funding,
which simulates a funded attacker/user — never an owner/admin role.

## Tests (all pass, 6/6)

| Test | What it proves |
|---|---|
| `testSelfDealFarmsFundingAccount` | **The finding**: self-deal farms 292 MOR from the funding account, stake refunded in full |
| `testApprovalNotBoundToUser` | Finding B (Low, $0): provider approval not bound to its user |
| `testClaimForProviderRevertsAfterLateClose` | Finding C (Low, $0): claim underflows after a late close |
| other tests | Dismissed candidates (diamondCut owner-only, close/session guards, stipend limits) |
