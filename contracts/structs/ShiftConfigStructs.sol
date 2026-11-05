// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Discriminator for ShiftConfig payloads stored in the shared
// NftSettings.extraData field. Any payload whose first word doesn't match
// this magic is treated as belonging to another consumer (or as no opt-in at
// all) and the shift check is skipped silently. A magic-matching but
// otherwise corrupted payload reverts loudly — the Sickle owner expressed
// shift-rebalance intent, so we surface the bug rather than silently ignore
// it.
//
// Literal value (for off-chain encoders that prefer not to re-derive):
// bytes4(keccak256("shift.v1")) == 0x02493ba4
bytes4 constant SHIFT_MAGIC = bytes4(keccak256("shift.v1"));

// Opt-in geometry for keeper-driven rebalances. `magic` must equal
// SHIFT_MAGIC. When `enabled` is true, `rebalanceFor` requires the pool's
// current tick to be outside the old position's range, or still inside the
// range but past exactly one configured rebalance buffer threshold. The new
// ticks must match an exact target derived from `entryTickSpacesUp`/
// `entryTickSpacesDown`:
//
//   - shifted up:
//       tick >= oldUpper, or tick in range and
//       tick >= oldUpper + bufferTicksAbove.
//       newLower = floor(tick, ts) - up * ts;
//       newUpper = newLower + (oldUpper - oldLower).
//   - shifted down:
//       tick < oldLower, or tick in range and
//       tick < oldLower - bufferTicksBelow.
//       newUpper = floor(tick, ts) + (down + 1) * ts;
//       newLower = newUpper - (oldUpper - oldLower).
//
// If overlapping negative buffers make both in-range directions true, the
// shift is ambiguous and reverts rather than letting the keeper choose.
//
// where `ts = pool.tickSpacing`. Position width is preserved from the old
// position. Both fields are signed tick-spaces — `1` means "after the
// rebalance the tick sits one tick-space inside the new range from the near
// edge"; `0` straddles; `-1` leaves the new range one tick-space short of
// the tick. The keeper computes these off-chain; the strategy verifies the
// exact equality. Values are evaluated in int24 tick arithmetic, so keep them
// within the pool's tick-range/tick-spacing bounds.
struct ShiftConfig {
    bytes4 magic;
    bool enabled;
    int24 entryTickSpacesUp;
    int24 entryTickSpacesDown;
}
