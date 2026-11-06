package com.cozypi.cozysafe

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import io.flutter.plugin.common.MethodChannel

/** The 24 words in Google Block Store (lib/key_backup.dart), the Android twin of the iCloud
 *  Keychain copy. One entry per set of words, named by the key's fingerprint
 *  (`secret-key.<4 hex>`, ADR 0008); before that a single `secret-key`. Kept only when Google
 *  encrypts it end to end (the phone has a screen lock); a new phone restored from this Google
 *  account finds them and asks only for the vault password. */
object BlockStore {
    private const val NS = "com.cozypi.cozysafe."

    /** Only the names Dart uses: letters, digits, '-' and '.', after our own prefix. */
    private fun entry(name: String?): String? =
        name?.takeIf { it.isNotEmpty() && it.length <= 40 && it.all { c -> c.isLetterOrDigit() || c == '-' || c == '.' } }
            ?.let { NS + it }

    fun handle(context: Context, method: String, name: String?, bytes: ByteArray?, result: MethodChannel.Result) {
        val client = Blockstore.getClient(context)
        when (method) {
            // true once the words are kept with end-to-end encrypted backup.
            "store" -> {
                val key = entry(name)
                if (bytes == null || key == null) return result.success(false)
                client.isEndToEndEncryptionAvailable
                    .addOnSuccessListener { e2ee ->
                        if (!e2ee) return@addOnSuccessListener result.success(false)
                        val data = StoreBytesData.Builder()
                            .setKey(key)
                            .setBytes(bytes)
                            .setShouldBackupToCloud(true)
                            .build()
                        client.storeBytes(data)
                            .addOnSuccessListener { result.success(it == bytes.size) }
                            .addOnFailureListener { result.success(false) }
                    }
                    .addOnFailureListener { result.success(false) }
            }
            "find" -> {
                val key = entry(name) ?: return result.success(null)
                client.retrieveBytes(RetrieveBytesRequest.Builder().setKeys(listOf(key)).build())
                    .addOnSuccessListener { r -> result.success(r.blockstoreDataMap[key]?.bytes) }
                    .addOnFailureListener { result.success(null) }
            }
            // The names of every entry of ours, without the prefix.
            "keys" -> client.retrieveBytes(RetrieveBytesRequest.Builder().setRetrieveAll(true).build())
                .addOnSuccessListener { r ->
                    result.success(r.blockstoreDataMap.keys.filter { it.startsWith(NS) }.map { it.removePrefix(NS) })
                }
                .addOnFailureListener { result.success(emptyList<String>()) }
            "delete" -> {
                val key = entry(name) ?: return result.success(false)
                client.deleteBytes(DeleteBytesRequest.Builder().setKeys(listOf(key)).build())
                    .addOnSuccessListener { result.success(it) }
                    .addOnFailureListener { result.success(false) }
            }
            else -> result.notImplemented()
        }
    }
}
