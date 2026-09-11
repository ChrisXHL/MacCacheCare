import Foundation
@_silgen_name("care_pid_list") func carePIDList(_ pids: UnsafeMutablePointer<Int32>, _ capacity: Int32) -> Int32
@_silgen_name("care_pid_row") func carePIDRow(_ pid: Int32, _ parent: UnsafeMutablePointer<Int32>, _ rss: UnsafeMutablePointer<UInt64>, _ age: UnsafeMutablePointer<UInt64>, _ path: UnsafeMutablePointer<CChar>, _ capacity: Int32) -> Int32
@_silgen_name("care_metrics") func careMetrics(_ physical: UnsafeMutablePointer<UInt64>, _ compressed: UnsafeMutablePointer<UInt64>, _ wired: UnsafeMutablePointer<UInt64>, _ swap: UnsafeMutablePointer<UInt64>, _ pressure: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("care_arguments") func careArguments(_ pid: Int32, _ path: UnsafeMutablePointer<CChar>, _ capacity: Int32) -> Int32
@_silgen_name("care_connections") func careConnections(_ pid: Int32, _ socket: UnsafePointer<CChar>, _ port: Int32, _ daemon: Int32) -> Int32
@_silgen_name("care_downloading") func careDownloading(_ pid: Int32) -> Int32
