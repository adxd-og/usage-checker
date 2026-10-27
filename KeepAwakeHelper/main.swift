// omelette-keepawake — the privileged launchd daemon behind "keep awake with the lid closed"
// (spec 2026-10-26, § Helper). Its contract:
// - runs as root under launchd, registered by the app through SMAppService.daemon;
// - clears its own sleep flag (`pmset -a disablesleep 0`) at every start, before it listens:
//   a flag the state file does not claim (set by another tool or by hand) is left alone;
// - on SIGTERM (unload, the Login Items switch, unregister) clears an armed flag before exiting;
// - exits a minute after it goes idle; launchd starts it again on the app's next call or at boot;
// - accepts XPC only from com.usagetracker.app signed by the daemon's own team.
import Foundation

KeepAwakeDaemon.run()
