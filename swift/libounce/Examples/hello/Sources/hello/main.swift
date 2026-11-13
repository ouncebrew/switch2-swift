// A Switch 2 program that uses the Ounce library.
//
// Build it with:
//   sh $DEVKITPRO/swift/swiftpm/switch2-build.sh -c release
//
// The entry point is top-level code, not @_cdecl("main"), because SwiftPM
// generates main for an executable target. The body lives in a function
// because this package is tools-version 6.0, where file-scope `let` and `var`
// count as shared mutable state.

import Ounce

func run() {
    Console.initialize()
    Console.print("Hello from the Ounce library")

    // The SD card is where a homebrew program keeps anything it wants to
    // survive a restart. Mounting it is what makes sdmc:/ paths work.
    do {
        try FileSystem.mountSdCard()
        Console.print("sdmc: mounted")
    } catch {
        Console.print("could not mount sdmc: \(error)")
    }

    // OunceHEN is only present when the program was started from hbloader.
    if Hen.isAvailable {
        do {
            let hen = try Hen()
            let status = try hen.status
            Console.print("HEN pid \(status.processID), protocol \(status.protocolVersion)")
        } catch {
            Console.print("HEN session failed: \(error)")
        }
    } else {
        Console.print("not running under OunceHEN")
    }

    Console.print("Press + to exit")

    // The console is double buffered, so nothing above is on screen until
    // consoleUpdate runs. Console.print does that for each line.
    let pad = Pad()
    var frames = 0

    while Applet.isRunning {
        pad.update()

        if pad.buttonsDown.contains(.plus) {
            break
        }

        // Redraw once a second or so, so the stick readout stays current
        // without flooding the console.
        frames += 1
        if frames % 60 == 0 {
            let stick = pad.stick(0)
            Console.print("left stick: \(stick.x), \(stick.y)")
        }
    }

    Console.print("Goodbye")
    Console.exit()
}

run()
