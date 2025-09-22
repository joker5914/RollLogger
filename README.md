RollLogger
----------
Logs only YOUR /roll results (from system messages), saves them in SavedVariables along with a CSV buffer.

Commands:
  /rolllog           -> quick stats
  /rolllog stats     -> same as above
  /rolllog export    -> rebuild the CSV buffer in SavedVariables
  /rolllog reset     -> clears data

Export:
  1) Type /rolllog export
  2) /reload (or logout) so SavedVariables are written
  3) Run Export-RollLogger.ps1 (below) to generate Interface\AddOns\RollLogger\Rolls.csv
