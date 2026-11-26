package com.dvplayer.core.vfs.nfs

import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * 单测用的最小 NFSv3 服务器，只监听回环、只在测试进程里活着。
 *
 * 它实现的是真实协议（记录标记、XDR、AUTH_SYS、MOUNT、READDIRPLUS 分页），
 * 不是打桩：客户端那侧的帧格式、凭据布局、句柄与分页 cookie 都被真跑一遍。
 * 真 NAS 上跑不了 CI，用这个覆盖协议层，真实服务器只用来做最后的对照。
 */
class FakeNfsServer(private val exportPath: String = "/export") : Closeable {

    class Node internal constructor(
        val path: String,
        val isDir: Boolean,
        var content: ByteArray,
    ) {
        var mtime: Int = 1_700_000_000
        internal var id: Long = 0
        val name: String get() = path.substringAfterLast('/')
    }

    private val nodes = LinkedHashMap<String, Node>()
    private val byId = HashMap<Long, String>()
    private var nextId = 1L

    /** 记录收到的过程调用，断言「客户端真的连过」时用。 */
    val calls = CopyOnWriteArrayList<String>()

    @Volatile
    internal var lastAuth: AuthSys? = null
        private set

    @Volatile
    var lastAuthFlavor: Int = -1
        private set

    private val server = ServerSocket(0, 32, InetAddress.getLoopbackAddress())
    private val running = AtomicBoolean(true)

    val port: Int get() = server.localPort

    init {
        put(exportPath, isDir = true)
        thread(isDaemon = true, name = "fake-nfs") { acceptLoop() }
    }

    /** 建目录或文件；中间目录自动补齐。 */
    fun put(path: String, isDir: Boolean, content: ByteArray = ByteArray(0)): Node {
        require(path.startsWith("/")) { "路径要以 / 开头：$path" }
        var parent = parentOf(path)
        while (parent != null && !nodes.containsKey(parent)) {
            addNode(parent, isDir = true, content = ByteArray(0))
            parent = parentOf(parent)
        }
        return addNode(path, isDir, content)
    }

    fun node(path: String): Node = nodes[path] ?: error("没有这个节点：$path")

    private fun addNode(path: String, isDir: Boolean, content: ByteArray): Node {
        nodes[path]?.let { return it }
        val node = Node(path, isDir, content)
        node.id = nextId++
        nodes[path] = node
        byId[node.id] = path
        return node
    }

    private fun parentOf(path: String): String? {
        val idx = path.lastIndexOf('/')
        if (idx <= 0) return null
        return path.substring(0, idx)
    }

    private fun childrenOf(dirPath: String): List<Node> {
        val base = if (dirPath.endsWith("/")) dirPath else "$dirPath/"
        return nodes.values
            .filter { it.path.startsWith(base) && !it.path.substring(base.length).contains('/') }
            .sortedBy { it.name }
    }

    override fun close() {
        running.set(false)
        runCatching { server.close() }
    }

    // ---- 传输层 ----

    private fun acceptLoop() {
        while (running.get()) {
            val socket = try {
                server.accept()
            } catch (t: Throwable) {
                return
            }
            thread(isDaemon = true, name = "fake-nfs-conn") {
                socket.use { s ->
                    val input = DataInputStream(s.getInputStream())
                    val output = DataOutputStream(s.getOutputStream())
                    while (running.get()) {
                        val payload = try {
                            readRecord(input)
                        } catch (t: Throwable) {
                            return@use
                        }
                        val reply = try {
                            handle(payload)
                        } catch (t: Throwable) {
                            System.err.println("fake-nfs 调用失败：" + t)
                            t.printStackTrace()
                            return@use
                        }
                        output.writeInt(Int.MIN_VALUE or reply.size)
                        output.write(reply)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun readRecord(input: DataInputStream): ByteArray {
        val parts = ArrayList<ByteArray>()
        var total = 0
        while (true) {
            val marker = input.readInt()
            val length = marker and 0x7fffffff
            val chunk = ByteArray(length)
            input.readFully(chunk)
            parts += chunk
            total += length
            if (marker < 0) break
        }
        val out = ByteArray(total)
        var pos = 0
        parts.forEach { p ->
            System.arraycopy(p, 0, out, pos, p.size)
            pos += p.size
        }
        return out
    }

    // ---- RPC ----

    private fun handle(payload: ByteArray): ByteArray {
        val r = XdrReader(payload)
        val xid = r.u32()
        r.u32()                                   // CALL
        r.u32()                                   // rpcvers
        val program = r.u32()
        val version = r.u32()
        val procedure = r.u32()

        val flavor = r.u32()
        val credLength = r.u32()
        val cred = r.fixed(credLength)
        val verifierFlavor = r.u32()
        val verifierLength = r.u32()
        r.fixed(verifierLength)
        lastAuthFlavor = flavor
        lastAuth = if (flavor == OncRpcClient.AUTH_SYS) parseAuth(cred) else null
        calls += "$program/$version/$procedure"

        var accept = OncRpcClient.SUCCESS
        val body = XdrWriter(1024)

        when {
            program == OncRpcClient.PROG_MOUNT && version == OncRpcClient.VERS_MOUNT -> {
                when (procedure) {
                    1 -> mount(r, body)
                    3 -> Unit                     // UMNT
                    else -> accept = OncRpcClient.PROC_UNAVAIL
                }
            }
            program == OncRpcClient.PROG_NFS && version == OncRpcClient.VERS_NFS -> {
                when (procedure) {
                    0 -> Unit                     // NULL
                    1 -> getattr(r, body)
                    3 -> lookup(r, body)
                    6 -> read(r, body)
                    17 -> readdirPlus(r, body)
                    else -> accept = OncRpcClient.PROC_UNAVAIL
                }
            }
            else -> accept = OncRpcClient.PROG_UNAVAIL
        }

        val out = XdrWriter(64 + body.length)
        out.u32(xid)
        out.u32(1)                                // REPLY
        out.u32(0)                                // MSG_ACCEPTED
        out.u32(0).u32(0)                         // verifier AUTH_NULL
        out.u32(accept)
        if (accept == OncRpcClient.SUCCESS) out.fixed(body.toByteArray())
        return out.toByteArray()
    }

    private fun parseAuth(body: ByteArray): AuthSys {
        val r = XdrReader(body)
        r.u32()                                   // stamp
        val machine = r.string()
        val uid = r.u32()
        val gid = r.u32()
        val count = r.u32()
        val gids = (0 until count.coerceIn(0, 16)).map { r.u32() }
        return AuthSys(uid, gid, machine, gids)
    }

    // ---- 过程实现 ----

    private fun mount(r: XdrReader, out: XdrWriter) {
        val path = r.string()
        val node = nodes[path]
        if (node == null || !node.isDir) {
            out.u32(2)                            // MNT3ERR_NOENT
            return
        }
        out.u32(0)
        out.opaque(handleOf(node))
        out.u32(1).u32(OncRpcClient.AUTH_SYS)     // auth_flavors<>
    }

    private fun getattr(r: XdrReader, out: XdrWriter) {
        val path = r.opaque().let { byId[idOf(it)] }
        val node = path?.let { nodes[it] }
        if (node == null) {
            out.u32(70)                           // NFS3ERR_STALE
            return
        }
        out.u32(0)
        out.fattr3(node)
    }

    private fun lookup(r: XdrReader, out: XdrWriter) {
        val dirPath = byId[idOf(r.opaque())]
        val name = r.string()
        val dir = dirPath?.let { nodes[it] }
        val child = dir?.let { nodes["${it.path.trimEnd('/')}/$name"] }
        if (dir == null) {
            out.u32(70)
            return
        }
        if (child == null) {
            out.u32(2)                            // NFS3ERR_NOENT
            return
        }
        out.u32(0)
        out.opaque(handleOf(child))
        out.bool(true).fattr3(child)
        out.bool(true).fattr3(dir)
    }

    private fun read(r: XdrReader, out: XdrWriter) {
        val path = byId[idOf(r.opaque())]
        val offset = r.u64()
        val count = r.u32()
        val node = path?.let { nodes[it] }
        if (node == null || node.isDir) {
            out.u32(70)
            return
        }
        val start = offset.coerceIn(0, node.content.size.toLong()).toInt()
        val end = minOf(node.content.size, start + count.coerceAtLeast(0))
        val data = node.content.copyOfRange(start, end)
        out.u32(0)
        out.bool(true).fattr3(node)
        out.u32(data.size)
        out.bool(end >= node.content.size)
        out.opaque(data)
    }

    private fun readdirPlus(r: XdrReader, out: XdrWriter) {
        val path = byId[idOf(r.opaque())]
        val cookie = r.u64()
        val verifier = r.fixed(8)
        r.u32()                                   // dircount
        val maxCount = r.u32().coerceAtLeast(1024)
        val dir = path?.let { nodes[it] }
        if (dir == null || !dir.isDir) {
            out.u32(70)
            return
        }

        val children = childrenOf(dir.path)
        val start = cookie.toInt().coerceIn(0, children.size)
        val page = ArrayList<Node>()
        var budget = 0
        var index = start
        while (index < children.size) {
            val child = children[index]
            val cost = 128 + child.name.toByteArray(Charsets.UTF_8).size
            if (page.isNotEmpty() && budget + cost > maxCount) break
            page += child
            budget += cost
            index++
        }
        val eof = index >= children.size

        out.u32(0)
        out.bool(true).fattr3(dir)
        out.fixed(verifier)
        var entryCookie = start.toLong()
        page.forEach { child ->
            entryCookie += 1
            out.bool(true)
            out.u64(child.id)
            out.string(child.name)
            out.u64(entryCookie)
            out.bool(true).fattr3(child)
            out.bool(true).opaque(handleOf(child))
        }
        out.bool(false)                           // entries 结束
        out.bool(eof)
    }

    private fun handleOf(node: Node): ByteArray {
        val handle = ByteArray(8)
        for (i in 0 until 4) handle[i] = (node.id ushr (8 * (3 - i))).toByte()
        handle[4] = 0x5A.toByte()
        handle[5] = 0x5A.toByte()
        handle[6] = 0x5A.toByte()
        handle[7] = 0x5A.toByte()
        return handle
    }

    private fun idOf(handle: ByteArray): Long {
        if (handle.size != 8) error("句柄长度不对：${handle.size}")
        var id = 0L
        for (i in 0 until 4) id = (id shl 8) or (handle[i].toLong() and 0xff)
        return id
    }

    private fun XdrWriter.fattr3(node: Node) {
        u32(if (node.isDir) 2 else 1)             // ftype3
        u32(if (node.isDir) 0x41ED else 0x81A4)   // mode
        u32(1)                                    // nlink
        u32(1000)                                 // uid
        u32(1000)                                 // gid
        u64(node.content.size.toLong())           // size
        u64(node.content.size.toLong())           // used
        u32(0).u32(0)                             // rdev
        u64(1)                                    // fsid
        u64(node.id)                              // fileid
        repeat(3) { u32(node.mtime).u32(0) }      // atime / mtime / ctime
    }
}
