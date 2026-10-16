import Foundation
import OmenCore
import PowerProtocol
var count=0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAILED: \(message)") }; count += 1
}
var a=FanSettings(), b=a
b.cpu=21;check(b.sameRequest(as:a),"Ignore inactive manual controls")
a.profile = .manual;b.profile = .manual
check(!b.sameRequest(as:a),"Changed target enables Apply")
b.cpu=a.cpu;check(b.sameRequest(as:a),"Successful identical request disables Apply")
b.gpu=0;check(!b.sameRequest(as:a),"Auto on one fan is a real change")
var s=FanSettings();s.profile = .curve
check(s.targets(temperature:nil)==nil,"Missing sensors reject curve")
check(s.targets(temperature:.nan)==nil,"Nonfinite sensors reject curve")
check(s.targets(temperature:0)?.0==35,"Curve clamps low endpoint")
check(s.targets(temperature:60)?.0==50,"Exact curve point")
check(s.targets(temperature:67.5)?.0==63,"Linear interpolation")
check(s.targets(temperature:120)?.1==100,"Full speed above hot endpoint")
s.points[1].percent=10;check(!s.valid,"Reject descending curve")
check(s.targets(temperature:55)==nil,"Invalid curve cannot run")
s=FanSettings();s.profile = .manual;s.cpu=0;s.gpu=100
check(s.valid,"Accept inclusive range 0–100")
check(s.targets(temperature:nil)?.0==0,"Zero passed through as firmware Auto")
s.cpu = -1;check(!s.valid,"Reject negative")
s.cpu = .nan;check(!s.valid,"Reject NaN")
s.cpu = 101;check(!s.valid,"Reject above 100")
s=FanSettings();s.profile = .eco;check(s.targets(temperature:nil)?.0==30,"Eco 30%")
s.profile = .performance;check(s.targets(temperature:nil)?.1==100,"Performance full")
check(TemperatureUnit.fahrenheit.value(100)==212,"Fahrenheit boiling")
check(TemperatureUnit.fahrenheit.value(0)==32,"Fahrenheit freezing")
check(TemperatureUnit.celsius.value(42)==42,"Celsius preserved")
s.profile = .manual;s.cpu=0;s.gpu=38
check(try! JSONDecoder().decode(FanSettings.self,from:JSONEncoder().encode(s))==s,"Fan preferences round trip")
var p=PowerSettings();p.followSource=true;p.batteryProfile = .eco;p.acProfile = .performance
check(try! JSONDecoder().decode(PowerSettings.self,from:JSONEncoder().encode(p))==p,"Power preferences round trip")
check(FanAnimation.revolutionDuration(rpm:nil)==nil,"Missing RPM does not animate")
check(FanAnimation.revolutionDuration(rpm:0)==nil,"Stopped fan does not animate")
check(FanAnimation.revolutionDuration(rpm:-1)==nil,"Reject negative RPM")
check(FanAnimation.revolutionDuration(rpm:15_001)==nil,"Reject out-of-range RPM")
check(FanAnimation.revolutionDuration(rpm:2_000)==7.2,"Known slow-motion duration")
check(FanAnimation.revolutionDuration(rpm:6_000)==2.4,"Full-speed duration")
check(FanAnimation.revolutionDuration(rpm:3_000)! == FanAnimation.revolutionDuration(rpm:6_000)!*2,"Double measured RPM doubles visual rotation rate")
check(FanAnimation.revolutionDuration(rpm:15_000) != nil,"Maximum telemetry boundary remains valid")
var cpuClock=RotorClock(),gpuClock=RotorClock()
cpuClock.setRPM(6000,at:0);gpuClock.setRPM(3000,at:0)
cpuClock.advance(to:1);gpuClock.advance(to:1)
check(abs(cpuClock.angle-gpuClock.angle*2)<0.000001,"Independent fans follow their own measured RPM")
let before=cpuClock.angle
cpuClock.setRPM(3000,at:1)
check(cpuClock.angle==before,"Changing RPM preserves angle")
cpuClock.advance(to:2)
check(abs(cpuClock.angle-before-gpuClock.angle)<0.000001,"New velocity applies after telemetry update")
cpuClock.setRPM(nil,at:2);let frozen=cpuClock.angle
cpuClock.advance(to:100)
check(cpuClock.angle==frozen,"Missing RPM freezes blades")
cpuClock.setRPM(6000,at:100)
check(cpuClock.angle==frozen,"Reattaching resumes without an angle reset")
cpuClock.advance(to:99)
check(cpuClock.angle==frozen,"Backward clocks cannot reverse the fan")
cpuClock.advance(to:.nan)
check(cpuClock.angle==frozen,"Nonfinite clocks cannot corrupt phase")
cpuClock.setRPM(0,at:101);let stopped=cpuClock.angle;cpuClock.advance(to:105)
check(cpuClock.angle==stopped,"Zero RPM remains stopped")
let actual = PowerPolicy.parse("Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\nUPS Power:\n lowpowermode 1\n")
check(actual == PowerPolicy(battery:true,ac:false), "Parse independent battery and AC; ignore UPS")
check(PowerPolicy.parse("AC Power:\n lowpowermode 0\n") == PowerPolicy(battery:nil,ac:false), "Missing battery stays unavailable")
check(PowerPolicy.parse("AC Power:\n lowpowermode 2\n") == nil, "Unknown mode does not become a guessed Boolean")
check(PowerPolicy.parse("unreadable") == nil, "Unreadable power policy does not become defaults")
var desiredPower=PowerSettings()
check(actual?.needsChange(desiredPower)==false, "Live system policy matches initial selection")
desiredPower.acLowPower=true
check(actual?.needsChange(desiredPower)==true, "AC change enables Apply")
desiredPower.acLowPower=false
check(actual?.needsChange(desiredPower)==false, "Reverting AC change disables Apply")
var localPower=PowerSettings()
localPower.acProfile = .performance
check(localPower.sameLocalRequest(as:PowerSettings()), "Inactive source profiles do not dirty Apply")
localPower.followSource=true
check(!localPower.sameLocalRequest(as:PowerSettings()), "Enabling source following dirties local preferences")
for battery in [false,true] {
 for ac in [false,true] {
  check(PowerRequestPolicy.arguments(battery:battery,ac:ac,changeBattery:true,changeAC:true) == ["-b","lowpowermode",battery ? "1":"0","-c","lowpowermode",ac ? "1":"0"], "Power helper exposes only fixed Boolean arguments")
 }
}
check(PowerRequestPolicy.arguments(battery:true,ac:true,changeBattery:false,changeAC:false).isEmpty, "No-op helper request has no command arguments")
check(PowerRequestPolicy.arguments(battery:true,ac:false,changeBattery:false,changeAC:true) == ["-c","lowpowermode","0"], "Do not change unrequested power source")
check(PowerRequestPolicy.authorized(clientUID:501,consoleUID:501), "Current console user is allowed")
check(!PowerRequestPolicy.authorized(clientUID:502,consoleUID:501), "Other local user rejected")
check(!PowerRequestPolicy.authorized(clientUID:0,consoleUID:501), "Root proxy is not the console user")
check(!PowerRequestPolicy.authorized(clientUID:501,consoleUID:nil), "No console session is rejected")
check(!PowerRequestPolicy.authorized(clientUID:201,consoleUID:201), "Guest/system account is rejected")
print("Passed \(count) control-policy checks.")
