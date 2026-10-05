package com.soyuz.kcomms.ui

import com.soyuz.kcomms.protocol.IdentityChanged

/** Main-thread owner of the user intent that permitted an admission request. */
class ForegroundAdmissionFence {
    var foreground: Boolean = false
        private set
    private var generation = 0L

    fun setForeground(value: Boolean) { foreground = value; invalidatePending() }
    fun invalidatePending() { generation += 1 }
    fun capture(): Long = generation
    fun requireCurrent(expected: Long) {
        if (!foreground || generation != expected) throw IdentityChanged()
    }
}
