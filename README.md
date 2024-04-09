# SM-NT-VIP
Sourcemod plugin for NT VIP mode (WIP) - Credits to DestroyGirl, Agiel, Rain and SoftAsHell

Thanks to DestroyGirl for implementing the game mode and the others for writing much of the code that I was simply able to copy, and for helping me with questions.

Also big shoutout to Agiel for the nt_windcond code which basically makes anything possible ontop of the CTG game mode, should be much easier to create alternative game modes now.

Right now if your server uses nt_windcond plugin by Agiel, this plugin will unload it for VIP maps until I can re-write this plugin to work with future versions of nt_wincond that support VIP.
There are various implementations of VIP so this plugin might break some of those as well until the gamemode is completed.

All you need to do to create a VIP map with this plugin is:  
1) Take any CTG map, remove the ghost spawns, add attacker (VIP team) ghost caps to wherever you want them to go for indicators, add one `trigger_once` called `vip_escape_point` that only responds to `vip_player` with a name filter - the trigger can be multiple brushes over different escape points but just 1 ent. Call map `nt_something_vip_something` gotta include `_vip`.
2) Add this vip plugin and smac plugin to server.
3) Now you have VIP mode on this map
