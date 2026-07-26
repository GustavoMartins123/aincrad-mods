# Experience Notifications

Shows the exact hero experience awarded by a confirmed enemy death as an
`EXP +N` entry in Echoes of Aincrad's native side-message stack.

The mod correlates `RODGameState.NotifyEnemyConfirmedDeath` with the host
player's next `RODPlayerState.CalcHeroLevelUp(AddExp)` call. It displays the
actual `AddExp` value rather than estimating the reward from the enemy class.
Quest rewards and other experience grants are not shown.

The message is an instance of the game's own `URODEventMessageWidget`, inserted
into the active `URODInfoMessageLogWidget.Information` panel. The native message
log owns its lifetime through `SetMessageTimer`; Lua does not retain a widget or
world object across travel.

If the confirmed-death, reward, or active message-stack contract is absent, the
operation reports an explicit error and does not create a substitute overlay.
