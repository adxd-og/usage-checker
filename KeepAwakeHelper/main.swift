// omelette-keepawake — the privileged launchd daemon behind "keep awake with the lid closed"
// (spec 2026-10-26, § Helper). Its contract:
// - runs as root under launchd, registered by the app through SMAppService.daemon;
// - clears the sleep flag (`pmset -a disablesleep 0`) at every start, before it listens;
// - on SIGTERM (unload, the Login Items switch, unregister) clears an armed flag before exiting;
// - exits a minute after it goes idle; launchd starts it again on the app's next call or at boot;
// - accepts XPC only from com.usagetracker.app signed by the daemon's own team.
import Foundation

KeepAwakeDaemon.run()
