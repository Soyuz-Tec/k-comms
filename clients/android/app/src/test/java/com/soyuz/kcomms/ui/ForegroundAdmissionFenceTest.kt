package com.soyuz.kcomms.ui

import com.soyuz.kcomms.protocol.IdentityChanged
import org.junit.Assert.assertThrows
import org.junit.Test

class ForegroundAdmissionFenceTest {
    @Test fun admissionReturningAfterBackgroundCannotStartEvenAfterForegroundReturns() {
        val owner = ForegroundAdmissionFence()
        owner.setForeground(true); val request = owner.capture()
        owner.setForeground(false)
        assertThrows(IdentityChanged::class.java) { owner.requireCurrent(request) }
        owner.setForeground(true)
        assertThrows(IdentityChanged::class.java) { owner.requireCurrent(request) }
        owner.requireCurrent(owner.capture())
    }

    @Test fun hangingUpInvalidatesPendingAdmissionWithoutBackgrounding() {
        val owner = ForegroundAdmissionFence()
        owner.setForeground(true); val request = owner.capture()
        owner.invalidatePending()
        assertThrows(IdentityChanged::class.java) { owner.requireCurrent(request) }
        owner.requireCurrent(owner.capture())
    }

    @Test fun logoutOrIdentityReplacementCannotCompleteOldForegroundRequest() {
        val owner = ForegroundAdmissionFence()
        owner.setForeground(true); val formerAccount = owner.capture()
        owner.invalidatePending()
        assertThrows(IdentityChanged::class.java) { owner.requireCurrent(formerAccount) }
    }
}
