package com.cozypi.cozysafe

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** An AES key made inside the Android Keystore (StrongBox where the phone has one, else
 *  the TEE), never readable by any app, that wraps the PIN's device key (lib/hw_key.dart):
 *  a copy of the app's storage taken off the phone cannot be used to try PINs elsewhere. */
object HwKey {
    private const val ALIAS = "cozysafe-pin-wrap"
    private const val IV = 12

    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        fun make(strongBox: Boolean): SecretKey {
            val spec = KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .apply { if (strongBox && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
                .build()
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply { init(spec) }
                .generateKey()
        }
        return try {
            make(strongBox = true)
        } catch (e: Exception) {
            make(strongBox = false) // no StrongBox: the TEE
        }
    }

    /** The IV, then the sealed bytes; null when the keystore cannot do it. */
    fun wrap(data: ByteArray): ByteArray? = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.iv + cipher.doFinal(data)
    } catch (e: Exception) {
        null
    }

    fun unwrap(blob: ByteArray): ByteArray? = try {
        val key = key(create = false)
        if (key == null || blob.size <= IV) {
            null
        } else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, blob, 0, IV))
            cipher.doFinal(blob, IV, blob.size - IV)
        }
    } catch (e: Exception) {
        null
    }
}
