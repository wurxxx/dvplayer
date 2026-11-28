package com.dvplayer.core.vfs.nfs

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

/**
 * ONC RPC（RFC 5531）的 TCP 客户端，只做同步请求-应答。
 *
 * NFSv3 用「记录标记」分帧：每条消息前面一个 4 字节标记，最高位表示最后
 * 一片，低 31 位是这一片的长度。大回复（比如 READDIRPLUS）会被切成多片，
 * 所以读的时候要循环拼到最高位为 1 为止。
 *
 * 认证只实现 AUTH_SYS（NFS 场景的事实标准）：uid / gid / 机器名。NFSv3 的
 * 授权完全靠服务器信任客户端给的 uid，这也是 A9 只支持 AUTH_SYS 的原因。
 */
internal class OncRpcClient(
    private val host: String,
    private val port: Int,
    private val auth: AuthSys? = null,
    private val connectTimeoutMs: Int = 5_000,
    private val readTimeoutMs: Int = 20_000,
) : Closeable {

    private var socket: Socket? = null
    private var input: DataInputStream? = null
    private var output: DataOutputStream? = null
    private val xid = AtomicInteger((Math.random() * Int.MAX_VALUE).toInt())

    /**
     * 发一次调用并解析回复头，返回已定位到「结果区」的读取器。
     *
     * [args] 必须已经是 4 字节对齐的 XDR 正文（[XdrWriter] 保证）。
     * 连接级失败（对端关了、超时）重连重试一次；RPC 层错误直接抛，
     * 重试也只会拿到同样的错误。
     */
    @Synchronized
    fun call(program: Int, version: Int, procedure: Int, args: XdrWriter): XdrReader {
        var attempt = 0
        while (true) {
            try {
                return callOnce(program, version, procedure, args)
            } catch (e: OncRpcException) {
                throw e
            } catch (e: java.io.IOException) {
                closeSocket()
                if (++attempt > 1) throw e
            }
        }
    }

    private fun callOnce(
        program: Int,
        version: Int,
        procedure: Int,
        args: XdrWriter,
    ): XdrReader {
        val out = ensureConnected()
        val id = nextXid()

        val message = XdrWriter(args.length + 96)
        message.u32(id)
        message.u32(MSG_CALL)
        message.u32(RPC_VERSION)
        message.u32(program)
        message.u32(version)
        message.u32(procedure)
        if (auth == null) {
            message.u32(AUTH_NULL).u32(0)
        } else {
            val body = XdrWriter(64)
                .u32(0)                       // stamp
                .string(auth.machine)
                .u32(auth.uid)
                .u32(auth.gid)
                .u32(auth.gids.size)
            auth.gids.forEach { body.u32(it) }
            val bytes = body.toByteArray()
            message.u32(AUTH_SYS).u32(bytes.size).fixed(bytes)
        }
        message.u32(AUTH_NULL).u32(0)          // verifier
        message.fixed(args.toByteArray())       // 过程参数
        val payload = message.toByteArray()

        out.writeInt(LAST_FRAGMENT or payload.size)   // 单分片发送
        out.write(payload)
        out.flush()

        val reply = readRecord(ensureInput())
        return checkReplyHeader(reply, id)
    }

    /** 拼完一个记录标记保护的消息。 */
    private fun readRecord(input: DataInputStream): ByteArray {
        var result: ByteArray? = null
        var total = 0
        while (true) {
            val marker = input.readInt()
            val length = marker and 0x7fffffff
            if (length > MAX_MESSAGE) {
                throw OncRpcException("RPC 分片过大：$length")
            }
            val chunk = ByteArray(length)
            input.readFully(chunk)
            val old = result
            if (old == null) {
                result = chunk
                total = length
            } else {
                result = ByteArray(total + length)
                System.arraycopy(old, 0, result, 0, total)
                System.arraycopy(chunk, 0, result, total, length)
                total += length
            }
            if (marker < 0) break
        }
        return result ?: throw EOFException("对端返回空 RPC 消息")
    }

    private fun checkReplyHeader(message: ByteArray, expectedXid: Int): XdrReader {
        val reader = XdrReader(message)
        val id = reader.u32()
        if (id != expectedXid) {
            throw OncRpcException("RPC xid 不匹配：期望 $expectedXid，收到 $id")
        }
        if (reader.u32() != MSG_REPLY) throw OncRpcException("不是 RPC 回复")
        when (reader.u32()) {
            REPLY_ACCEPTED -> {
                // 校验器：AUTH_NULL + 空正文，或者任何 flavor 加它的长度。
                reader.u32()
                val verifierLength = reader.u32()
                if (verifierLength > 0) reader.skip(verifierLength + pad(verifierLength))
                val accept = reader.u32()
                if (accept != SUCCESS) {
                    throw OncRpcException("RPC 被拒绝：${acceptStatName(accept)}")
                }
            }
            REPLY_DENIED -> {
                val reject = reader.u32()
                val detail = if (reject == RPC_MISMATCH) {
                    "版本不匹配（${reader.u32()}..${reader.u32()}）"
                } else {
                    "认证失败（auth_stat=${reader.u32()}）"
                }
                throw OncRpcException("RPC 被拒绝：$detail")
            }
            else -> throw OncRpcException("未知的 RPC 回复类型")
        }
        return reader
    }

    private fun nextXid(): Int = xid.updateAndGet { (it + 1) and 0x7fffffff }

    private fun ensureConnected(): DataOutputStream {
        val existing = output
        if (existing != null) return existing
        val s = Socket()
        s.tcpNoDelay = true
        s.soTimeout = readTimeoutMs
        s.connect(InetSocketAddress(host, port), connectTimeoutMs)
        socket = s
        val os = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 64 * 1024))
        output = os
        input = DataInputStream(BufferedInputStream(s.getInputStream(), 64 * 1024))
        return os
    }

    private fun ensureInput(): DataInputStream =
        input ?: throw OncRpcException("RPC 连接未建立")

    private fun closeSocket() {
        runCatching { input?.close() }
        runCatching { output?.close() }
        runCatching { socket?.close() }
        input = null
        output = null
        socket = null
    }

    override fun close() = closeSocket()

    private fun pad(n: Int) = (4 - (n and 3)) and 3

    private fun acceptStatName(code: Int): String = when (code) {
        PROG_UNAVAIL -> "程序不可用"
        PROG_MISMATCH -> "程序版本不匹配"
        PROC_UNAVAIL -> "过程不可用"
        GARBAGE_ARGS -> "参数畸形"
        SYSTEM_ERR -> "服务端错误"
        else -> "accept_stat=$code"
    }

    companion object {
        const val MSG_CALL = 0
        const val MSG_REPLY = 1
        const val RPC_VERSION = 2

        const val AUTH_NULL = 0
        const val AUTH_SYS = 1

        const val REPLY_ACCEPTED = 0
        const val REPLY_DENIED = 1
        const val RPC_MISMATCH = 0

        const val SUCCESS = 0
        const val PROG_UNAVAIL = 1
        const val PROG_MISMATCH = 2
        const val PROC_UNAVAIL = 3
        const val GARBAGE_ARGS = 4
        const val SYSTEM_ERR = 5

        const val PROG_PORTMAPPER = 100000
        const val PROG_MOUNT = 100005
        const val PROG_NFS = 100003

        const val VERS_PORTMAPPER = 2
        const val VERS_MOUNT = 3
        const val VERS_NFS = 3

        /** IPPROTO_TCP，rpcbind 的 GETPORT 用它选传输层。 */
        const val PROTO_TCP = 6

        private const val LAST_FRAGMENT = Int.MIN_VALUE
        private const val MAX_MESSAGE = 8 * 1024 * 1024
    }
}

/** AUTH_SYS 凭据：NFSv3 的授权就是这几个数字。 */
internal data class AuthSys(
    val uid: Int,
    val gid: Int,
    val machine: String = "dvplayer",
    val gids: List<Int> = emptyList(),
)

class OncRpcException(message: String) : java.io.IOException(message)
