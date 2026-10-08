import Foundation
// jarvisfan auto | jarvisfan <rpm>   (runs setuid root)
setuid(0)
let a = CommandLine.arguments.dropFirst()
guard let arg = a.first else { print("usage: jarvisfan auto|<rpm>"); exit(2) }
let smc = SMC.shared
let n = Int(smc.read("FNum") ?? 0)
guard n > 0 else { print("no fans"); exit(1) }
let rpm: Double? = arg == "auto" ? nil : Double(arg)
if arg != "auto" && rpm == nil { print("bad rpm"); exit(2) }
var ok = true
for i in 0..<n { ok = smc.setFan(i, rpm: rpm) && ok }
print(ok ? "ok" : "failed (need root?)"); exit(ok ? 0 : 1)
