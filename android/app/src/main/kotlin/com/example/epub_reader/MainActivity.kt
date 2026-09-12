package com.example.epub_reader

import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "epub_reader/saf"
        private const val FILE_REQUEST = 4101
        private const val FOLDER_REQUEST = 4102
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickEpubFile" -> pickFile(result)
                "pickFolder" -> pickFolder(result)
                "materializeUri" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) result.error("BAD_URI", "URI가 없습니다.", null)
                    else materialize(Uri.parse(uri), result)
                }
                "listEpubUris" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) result.error("BAD_URI", "URI가 없습니다.", null)
                    else result.success(listEpubUris(Uri.parse(uri)))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pickFile(result: MethodChannel.Result) {
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/epub+zip"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/epub+zip", "application/zip", "application/octet-stream"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, FILE_REQUEST)
    }

    private fun pickFolder(result: MethodChannel.Result) {
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        startActivityForResult(intent, FOLDER_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FILE_REQUEST && requestCode != FOLDER_REQUEST) return
        val result = pendingResult ?: return
        pendingResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            val takeFlags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: SecurityException) { }
        result.success(uri.toString())
    }

    private fun materialize(uri: Uri, result: MethodChannel.Result) {
        try {
            val dir = File(cacheDir, "epub_imports")
            if (!dir.exists()) dir.mkdirs()
            val target = File(dir, "${sha256(uri.toString())}.epub")
            if (!target.exists()) {
                contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                } ?: throw IllegalStateException("EPUB을 열 수 없습니다.")
            }
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("READ_URI_FAILED", e.message, null)
        }
    }

    private fun listEpubUris(treeUri: Uri): String {
        val out = JSONArray()
        walkTree(treeUri, out)
        return out.toString()
    }

    private fun walkTree(treeUri: Uri, out: JSONArray) {
        val documentId = DocumentsContract.getTreeDocumentId(treeUri) ?: return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idIndex)
                val name = cursor.getString(nameIndex) ?: ""
                val mime = cursor.getString(mimeIndex) ?: ""
                val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walkTree(childUri, out)
                } else if (name.lowercase().endsWith(".epub")) {
                    out.put(childUri.toString())
                }
            }
        }
    }

    private fun sha256(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }
}
