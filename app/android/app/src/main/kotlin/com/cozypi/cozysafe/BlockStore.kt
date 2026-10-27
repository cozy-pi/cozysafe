package com.cozypi.cozysafe

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import io.flutter.plugin.common.MethodChannel

/** The 24 words in Google Block Store (lib/key_backup.dart), the Android twin of the iCloud
 *  Keychain copy: off unless turned on in Settings. Kept only when Google encrypts it end to
 *  end (the phone has a screen lock); a new phone restored from this Google account finds it
 *  and asks only for the vault password. */
object BlockStore {
    private const val KEY = "com.cozypi.cozysafe.secret-key"

    fun handle(context: Context, method: String, bytes: ByteArray?, result: MethodChannel.Result) {
        val client = Blockstore.getClient(context)
        when (method) {
            // true once the words are kept with end-to-end encrypted backup.
            "store" -> {
                if (bytes == null) return result.success(false)
                client.isEndToEndEncryptionAvailable
                    .addOnSuccessListener { e2ee ->
                        if (!e2ee) return@addOnSuccessListener result.success(false)
                        val data = StoreBytesData.Builder()
                            .setKey(KEY)
                            .setBytes(bytes)
                            .setShouldBackupToCloud(true)
                            .build()
                        client.storeBytes(data)
                            .addOnSuccessListener { result.success(it == bytes.size) }
                            .addOnFailureListener { result.success(false) }
                    }
                    .addOnFailureListener { result.success(false) }
            }
            "find" -> client.retrieveBytes(RetrieveBytesRequest.Builder().setKeys(listOf(KEY)).build())
                .addOnSuccessListener { r -> result.success(r.blockstoreDataMap[KEY]?.bytes) }
                .addOnFailureListener { result.success(null) }
            "delete" -> client.deleteBytes(DeleteBytesRequest.Builder().setKeys(listOf(KEY)).build())
                .addOnSuccessListener { result.success(it) }
                .addOnFailureListener { result.success(false) }
            else -> result.notImplemented()
        }
    }
}
