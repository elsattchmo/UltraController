@tool
class_name UltraLaunchPreset
extends Resource
## A set of game instances to start together (Project > Tools > Ultra > Launch, or
## `tools/launch.ps1 -Preset <name>`). Each entry: "<window>|<args...>", e.g.
##   "left|--host --players=1"      "right|--connect=127.0.0.1 --lag=120"
## A window of "headless" starts a console-less dedicated instance.

@export var title := ""
@export var instances: PackedStringArray = []
