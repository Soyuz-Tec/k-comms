package com.soyuz.kcomms.security

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.soyuz.kcomms.protocol.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class KeystoreCredentialVaultTest {
    @Test fun deviceVaultRoundTripsEncryptedCredentialsAndRefusesTamperedCiphertext() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vault = KeystoreCredentialVault(context)
        vault.clear()
        val tenant = "11111111-1111-4111-8111-111111111111"
        val user = "22222222-2222-4222-8222-222222222222"
        val device = "33333333-3333-4333-8333-333333333333"
        val authentication = Authentication("synthetic-access-token-private", "synthetic-refresh-token-private", 3600,
            Tenant(tenant), User(user, tenant, "Synthetic member", "human", accessScope = "workspace", status = "active"), Device(device, user))
        val expected = StoredState(StoredSession("https://example.test", "synthetic-generation", authentication))
        try {
            vault.save(expected)
            val file = File(context.noBackupFilesDir, "credential-v1.bin")
            val ciphertext = file.readBytes()
            assertFalse(ciphertext.toString(Charsets.UTF_8).contains(authentication.accessToken))
            assertFalse(ciphertext.toString(Charsets.UTF_8).contains(authentication.refreshToken))
            assertEquals(expected, vault.load())
            ciphertext[ciphertext.lastIndex] = (ciphertext.last().toInt() xor 1).toByte()
            file.writeBytes(ciphertext)
            assertEquals(StoredState(), vault.load())
            assertFalse(file.exists())
        } finally { vault.clear() }
    }
}
