# Verified measurements — physical iPhone 15 + Pixel 6 Pro

All values below are from actual iPhone test results on November 23–24, 2026 JST.

| Test | Generated tokens | Total seconds, including cold load | Tokens / total seconds |
| --- | ---: | ---: | ---: |
| Fixed 8-token split reference #1 | 8 | 106.584 | 0.075 |
| Fixed 8-token split reference #2 | 8 | 107.149 | 0.075 |
| Japanese chat with native Inkling template | 48 | 136.208 | 0.352 |
| Japanese chat | 128 | 165.914 | 0.772 |
| Long Japanese chat prompt, corrected prefill | 128 | 181.249 | 0.706 |
| User's chat conversation turn | 45 | 143.987 | 0.313 |

**Important:** The final column is strictly tokens / full elapsed seconds. It includes model verification and loading, RPC transfer, prefill and generation; **it is not a decode-only tok/s benchmark**. An earlier estimate of ~1.5–2 tok/s for steady-state generation was not independently measured and should not be cited as a measured result.

The logged split placement was 43/49 logical slots on Pixel RPC, with a 4,824.96 MiB RPC model buffer and 1,726.29 MiB iPhone CPU model buffer.

## Crash finding and fix

Two iPhone incident reports (November 23 at 23:55 and 23:58 JST) recorded SIGABRT in a llama.cpp decode assertion. The initial interactive chat prefill passed all prompt tokens in one call even though n_batch was 64. In pinned upstream llama.cpp, decode asserts that each call's token count is no larger than n_batch.

The corrected version chunks prefill to at most 64 tokens per call. It successfully decoded a 108-token prompt in 64 + 44 chunks and produced a Japanese answer without a new crash in that test.

These are isolated physical-device proof results, not reproducibility or stress-test guarantees.
