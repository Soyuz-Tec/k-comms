package com.soyuz.kcomms.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import com.soyuz.kcomms.protocol.Authentication
import com.soyuz.kcomms.protocol.WireJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@Serializable data class StoredSession(val origin: String, val lineage: String, val authentication: Authentication)
@Serializable data class PendingMessage(
    val commandId: String, val origin: String, val tenantId: String, val userId: String,
    val deviceId: String, val lineage: String, val conversationId: String, val body: String,
) {
    fun belongsTo(session: StoredSession) = origin == session.origin && lineage == session.lineage &&
        tenantId == session.authentication.tenant.id && userId == session.authentication.user.id &&
        deviceId == session.authentication.device.id
}
@Serializable data class StoredState(val session: StoredSession? = null, val outbox: List<PendingMessage> = emptyList())

interface CredentialVault {
    suspend fun load(): StoredState
    suspend fun save(state: StoredState)
    suspend fun clear()
}

/** Device-only key; no backup, plaintext preferences, logs or Intent credentials. */
class KeystoreCredentialVault(context: Context) : CredentialVault {
    private val file = AtomicFile(java.io.File(context.noBackupFilesDir, "credential-v1.bin"))
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val alias = "kcomms.credentials.v1"
    private val aad = "com.soyuz.kcomms:credentials:1".toByteArray(Charsets.UTF_8)

    private fun key(): SecretKey {
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }

    override suspend fun load(): StoredState = withContext(Dispatchers.IO) {
        if (!file.baseFile.exists()) return@withContext StoredState()
        try {
            require(file.baseFile.length() <= 1_048_576)
            val bytes = file.readFully()
            require(bytes.size >= 30 && bytes[0] == 1.toByte())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            cipher.updateAAD(aad)
            WireJson.decodeFromString<StoredState>(cipher.doFinal(bytes.copyOfRange(13, bytes.size)).toString(Charsets.UTF_8))
        } catch (_: Exception) {
            // An invalidated device key or tampered record cannot restore authority.
            file.delete()
            StoredState()
        }
    }

    override suspend fun save(state: StoredState) = withContext(Dispatchers.IO) {
        val plain = WireJson.encodeToString(StoredState.serializer(), state).toByteArray(Charsets.UTF_8)
        require(plain.size <= 1_000_000)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(aad)
        require(cipher.iv.size == 12)
        val output = file.startWrite()
        try {
            output.write(byteArrayOf(1) + cipher.iv + cipher.doFinal(plain))
            file.finishWrite(output)
        } catch (failure: Exception) {
            file.failWrite(output); throw failure
        } finally { plain.fill(0) }
    }

    override suspend fun clear() = withContext(Dispatchers.IO) { file.delete() }
}
