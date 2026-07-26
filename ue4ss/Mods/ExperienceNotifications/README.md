# Experience Notifications

Shows the exact hero experience awarded by a confirmed enemy death as an
`EXP +N` entry in Echoes of Aincrad's native side-message stack.

The mod reads the game's single
`RODGameState.ApplyAcquisition(Source, AcquisitionData)` transaction. It
requires `Source` to be a `RODEnemyCharacter` and displays the transaction's
exact `AcquisitionData.ExperiencePoint` value rather than estimating a reward
from the enemy class. Quest rewards and other non-enemy acquisitions are not
displayed.

The message is an instance of the game's own `URODEventMessageWidget`, inserted
into the active `URODInfoMessageLogWidget.Information` panel. The native message
log owns its lifetime through `SetMessageTimer`; Lua does not retain a widget or
world object across travel.

Before insertion, the mod writes `EXP +N` to the native rich-text block and
reads it back immediately. A rejected or replaced value prevents insertion and
reports an explicit display error. A later panel failure removes the partial
widget transactionally.

If the acquisition or active message-stack contract is absent, the operation
reports an explicit error and does not create a substitute overlay.
