package main

import (
	"fmt"
	"strings"
)

func statusDiagnosisLine(m MetricsSnapshot) string {
	for _, disk := range m.Disks {
		if disk.SmartStatus == smartStatusFailing {
			return "SMART 故障，请立即备份"
		}
	}
	if m.CPU.Usage > cpuHighThreshold {
		if processSnapshotFresh(m.ProcessStale) {
			if proc, ok := leadingCPUProcess(m.TopProcesses, 50); ok {
				return fmt.Sprintf("%s 处理器占用过高", shorten(proc.Name, 18))
			}
		}
		return "处理器负载过高"
	}
	if m.Memory.Pressure == "warn" || m.Memory.Pressure == "critical" || m.Memory.UsedPercent > memHighThreshold {
		if processSnapshotFresh(m.ProcessStale) {
			if proc, ok := leadingMemoryProcess(m.TopProcesses); ok && proc.Memory > 0 {
				return fmt.Sprintf("%s 内存压力", shorten(proc.Name, 18))
			}
		}
		return "内存压力过高"
	}
	if disk, ok := rootDisk(m.Disks); ok && disk.UsedPercent > diskCritThreshold {
		free := uint64(0)
		if disk.Total > disk.Used {
			free = disk.Total - disk.Used
		}
		return fmt.Sprintf("磁盘空间不足，剩余 %s", humanBytesShort(free))
	}
	for _, battery := range m.Batteries {
		if battery.Capacity > 0 && battery.Capacity < batteryCapWarn {
			return "电池健康度低"
		}
		if battery.CycleCount > batteryCycleWarn {
			return "电池循环次数过高"
		}
	}
	if m.Thermal.CPUTemp > thermalNormalThreshold {
		return "处理器温度过高"
	}
	if totalIO := m.DiskIO.ReadRate + m.DiskIO.WriteRate; totalIO > ioHighThreshold {
		return "磁盘 I/O 繁忙"
	}
	if strings.Contains(m.HealthScoreMsg, ":") {
		return m.HealthScoreMsg
	}
	return "一切正常"
}

func leadingCPUProcess(procs []ProcessInfo, threshold float64) (ProcessInfo, bool) {
	var best ProcessInfo
	for i, proc := range procs {
		if i == 0 || proc.CPU > best.CPU {
			best = proc
		}
	}
	if best.CPU < threshold {
		return ProcessInfo{}, false
	}
	return best, true
}

func leadingMemoryProcess(procs []ProcessInfo) (ProcessInfo, bool) {
	var best ProcessInfo
	for i, proc := range procs {
		if i == 0 || proc.Memory > best.Memory {
			best = proc
		}
	}
	return best, len(procs) > 0
}

func rootDisk(disks []DiskStatus) (DiskStatus, bool) {
	for _, disk := range disks {
		if disk.Mount == "/" {
			return disk, true
		}
	}
	if len(disks) == 0 {
		return DiskStatus{}, false
	}
	return disks[0], true
}
