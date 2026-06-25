/*
 * coderyoMC L1 pathfinding-elision validation — minimal protocol-776 login bot.
 *
 * Connects to a local (offline-mode) server, completes Handshake -> Login ->
 * Configuration -> Play, then idles as a stationary PLAYER target so summoned mobs
 * acquire it via MeleeAttackGoal and we can populate distance bands relative to it.
 * It answers keep-alives in both Configuration and Play so the connection stays up,
 * and acknowledges the configuration-finish so it transitions into Play (and thus
 * appears in `/list` and becomes a valid aggro target).
 *
 * Deliberately minimal: it does NOT parse world/chunk data — it skips every packet it
 * does not care about by length-prefix framing. No encryption (offline mode), no
 * compression negotiation beyond honoring a set-compression threshold by switching the
 * frame codec. Single-file, no deps; compile with `javac MiniBot.java`.
 *
 * Args: <host> <port> <name> <seconds>
 */
import java.io.*;
import java.net.*;
import java.util.zip.*;

public class MiniBot {
    static int compressionThreshold = -1; // -1 => no compression
    static final boolean TRACE = System.getenv("BOT_TRACE") != null;

    public static void main(String[] args) throws Exception {
        String host = args.length > 0 ? args[0] : "127.0.0.1";
        int port = args.length > 1 ? Integer.parseInt(args[1]) : 15565;
        String name = args.length > 2 ? args[2] : "L1Target";
        int seconds = args.length > 3 ? Integer.parseInt(args[3]) : 300;

        Socket sock = new Socket();
        sock.connect(new InetSocketAddress(host, port), 10000);
        sock.setTcpNoDelay(true);
        DataInputStream in = new DataInputStream(new BufferedInputStream(sock.getInputStream()));
        DataOutputStream out = new DataOutputStream(new BufferedOutputStream(sock.getOutputStream()));

        // ---- Handshake (state 1=status, 2=login) -> login ----
        ByteArrayOutputStream hs = new ByteArrayOutputStream();
        writeVarInt(hs, 0x00);            // handshake packet id
        writeVarInt(hs, 776);             // protocol version
        writeString(hs, host);            // server address
        hs.write((port >> 8) & 0xFF); hs.write(port & 0xFF); // unsigned short
        writeVarInt(hs, 2);               // next state: login
        sendFrame(out, hs.toByteArray());

        // ---- Login Start ----
        ByteArrayOutputStream ls = new ByteArrayOutputStream();
        writeVarInt(ls, 0x00);            // login start
        writeString(ls, name);
        // offline UUID (java.util.UUID nameUUIDFromBytes of "OfflinePlayer:" + name)
        java.util.UUID uuid = java.util.UUID.nameUUIDFromBytes(("OfflinePlayer:" + name).getBytes("UTF-8"));
        writeLong(ls, uuid.getMostSignificantBits());
        writeLong(ls, uuid.getLeastSignificantBits());
        sendFrame(out, ls.toByteArray());

        System.out.println("[bot] login start sent as " + name + " (" + uuid + ")");

        boolean inConfig = false, inPlay = false;
        long deadline = System.currentTimeMillis() + seconds * 1000L;

        while (System.currentTimeMillis() < deadline) {
            byte[] pkt;
            try {
                sock.setSoTimeout(2000);
                pkt = readFrame(in);
            } catch (SocketTimeoutException te) {
                continue;
            } catch (EOFException eof) {
                System.out.println("[bot] connection closed by server");
                break;
            } catch (SocketException se) {
                System.out.println("[bot] socket: " + se.getMessage());
                break;
            }
            if (pkt == null) break;
            ByteArrayInputStream pin = new ByteArrayInputStream(pkt);
            int id = readVarInt(pin);
            String st = inPlay ? "PLAY" : (inConfig ? "CONFIG" : "LOGIN");
            if (TRACE) System.out.println("[bot] <- " + st + " id=0x" + Integer.toHexString(id) + " len=" + pkt.length);

            if (!inConfig && !inPlay) {
                // LOGIN state
                if (id == 0x03) { // Set Compression
                    compressionThreshold = readVarInt(pin);
                    System.out.println("[bot] set-compression threshold=" + compressionThreshold);
                } else if (id == 0x02) { // Login Success
                    System.out.println("[bot] login success -> ack, entering configuration");
                    ByteArrayOutputStream ack = new ByteArrayOutputStream();
                    writeVarInt(ack, 0x03); // Login Acknowledged
                    sendFrame(out, ack.toByteArray());
                    inConfig = true;
                    // Serverbound Client Information (config 0x00) — required before the server
                    // will finish configuration.
                    ByteArrayOutputStream ci = new ByteArrayOutputStream();
                    writeVarInt(ci, 0x00);
                    writeString(ci, "en_us");   // locale
                    ci.write(8);                 // view distance
                    writeVarInt(ci, 0);          // chat mode: enabled
                    ci.write(1);                 // chat colors: true
                    ci.write(0x7F);              // displayed skin parts
                    writeVarInt(ci, 1);          // main hand: right
                    ci.write(0);                 // enable text filtering: false
                    ci.write(1);                 // allow server listings: true
                    writeVarInt(ci, 0);          // particle status: all
                    sendFrame(out, ci.toByteArray());
                } else if (id == 0x00) { // Login Disconnect
                    System.out.println("[bot] LOGIN DISCONNECT: " + new String(pkt, 1, pkt.length - 1, "UTF-8"));
                    break;
                } else if (id == 0x04) { // Login Plugin Request -> respond "not understood"
                    int msgId = readVarInt(pin);
                    ByteArrayOutputStream resp = new ByteArrayOutputStream();
                    writeVarInt(resp, 0x02); // Login Plugin Response
                    writeVarInt(resp, msgId);
                    resp.write(0); // successful=false
                    sendFrame(out, resp.toByteArray());
                }
            } else if (inConfig) {
                // CONFIGURATION state. Packet ids (clientbound, 1.21.x):
                //   Keep Alive = 0x04, Ping = 0x05, Disconnect = 0x02, Finish Config = 0x03
                if (id == 0x04) { // Keep Alive (config)
                    long ka = readLong(pin);
                    ByteArrayOutputStream r = new ByteArrayOutputStream();
                    writeVarInt(r, 0x04); // serverbound Keep Alive (config)
                    writeLong(r, ka);
                    sendFrame(out, r.toByteArray());
                } else if (id == 0x05) { // Ping (config)
                    int pingId = readInt(pin);
                    ByteArrayOutputStream r = new ByteArrayOutputStream();
                    writeVarInt(r, 0x05); // Pong (config)
                    writeInt(r, pingId);
                    sendFrame(out, r.toByteArray());
                } else if (id == 0x0E) { // Select Known Packs (clientbound) -> reply empty
                    ByteArrayOutputStream r = new ByteArrayOutputStream();
                    writeVarInt(r, 0x07); // serverbound Select Known Packs
                    writeVarInt(r, 0);    // 0 known packs
                    sendFrame(out, r.toByteArray());
                } else if (id == 0x03) { // Finish Configuration -> ack
                    ByteArrayOutputStream r = new ByteArrayOutputStream();
                    writeVarInt(r, 0x03); // Acknowledge Finish Configuration
                    sendFrame(out, r.toByteArray());
                    inConfig = false; inPlay = true;
                    playStartMs = System.currentTimeMillis();
                    System.out.println("[bot] entered PLAY state");
                } else if (id == 0x02) { // Disconnect (config)
                    System.out.println("[bot] CONFIG DISCONNECT");
                    break;
                }
                // ignore registry data / other config packets (we don't need them)
            } else { // inPlay
                // PLAY state. The keep-alive is the only clientbound play packet whose payload is
                // exactly an 8-byte long (frame = 1-byte id + 8-byte long = 9 bytes). Detect it by
                // shape (robust across id drift) and echo the long via serverbound Keep Alive 0x1C.
                // The real keep-alive: a periodic len=9 clientbound packet carrying a large
                // non-zero challenge (Paper uses a millisecond-derived value, never 0 and never
                // tiny). Other 8-byte packets at join (set-time=0, velocity=0) read as 0/small and
                // must NOT be echoed (doing so triggers "keepalive response without matching
                // challenge"). We learn the keep-alive id from the first such packet and lock to it.
                // Clientbound PLAY Keep Alive = 0x2C (id 44; the addPacket count INCLUDES the
                // bundle delimiter at id 0). Echo its 8-byte challenge via serverbound 0x1C.
                if (id == CB_PLAY_KEEPALIVE) {
                    long v = readLong(pin);
                    if (TRACE) System.out.println("[bot] -> keepalive resp " + v);
                    ByteArrayOutputStream r = new ByteArrayOutputStream();
                    writeVarInt(r, SB_PLAY_KEEPALIVE);
                    writeLong(r, v);
                    sendFrame(out, r.toByteArray());
                }
                // (Play Ping is optional for staying connected; keep-alive alone suffices.)
            }
        }

        System.out.println("[bot] done (inPlay=" + inPlay + ")");
        try { sock.close(); } catch (Exception ignore) {}
    }

    // Protocol-776 PLAY ids (verified against GameProtocols.java registration order; the clientbound
    // count INCLUDES the bundle delimiter at id 0, the serverbound count does not):
    //   clientbound Keep Alive = 0x2C
    //   serverbound Keep Alive = 0x1C
    static final int CB_PLAY_KEEPALIVE = 0x2C;
    static final int SB_PLAY_KEEPALIVE = 0x1C;
    static long playStartMs = Long.MAX_VALUE;

    // ---------- frame codec (handles optional zlib compression) ----------
    static void sendFrame(DataOutputStream out, byte[] data) throws IOException {
        if (TRACE && data.length > 0) {
            int sid = data[0] & 0xFF; // good enough for single-byte ids
            System.out.println("[bot] -> id=0x" + Integer.toHexString(sid) + " len=" + data.length);
        }
        if (compressionThreshold >= 0) {
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            if (data.length >= compressionThreshold) {
                Deflater d = new Deflater();
                d.setInput(data); d.finish();
                byte[] buf = new byte[8192];
                ByteArrayOutputStream comp = new ByteArrayOutputStream();
                while (!d.finished()) { int n = d.deflate(buf); comp.write(buf, 0, n); }
                d.end();
                writeVarInt(body, data.length);     // data length (uncompressed)
                body.write(comp.toByteArray());
            } else {
                writeVarInt(body, 0);               // 0 => uncompressed
                body.write(data);
            }
            byte[] b = body.toByteArray();
            ByteArrayOutputStream frame = new ByteArrayOutputStream();
            writeVarInt(frame, b.length);
            frame.write(b);
            out.write(frame.toByteArray()); out.flush();
        } else {
            ByteArrayOutputStream frame = new ByteArrayOutputStream();
            writeVarInt(frame, data.length);
            frame.write(data);
            out.write(frame.toByteArray()); out.flush();
        }
    }

    static byte[] readFrame(DataInputStream in) throws IOException {
        int len = readVarInt(in);
        if (len <= 0) return new byte[0];
        byte[] raw = new byte[len];
        in.readFully(raw);
        if (compressionThreshold >= 0) {
            ByteArrayInputStream bin = new ByteArrayInputStream(raw);
            int dataLen = readVarInt(bin);
            int headerLen = raw.length - bin.available();
            if (dataLen == 0) {
                byte[] out = new byte[raw.length - headerLen];
                System.arraycopy(raw, headerLen, out, 0, out.length);
                return out;
            } else {
                Inflater inf = new Inflater();
                inf.setInput(raw, headerLen, raw.length - headerLen);
                byte[] out = new byte[dataLen];
                try { inf.inflate(out); } catch (DataFormatException e) { throw new IOException(e); }
                inf.end();
                return out;
            }
        }
        return raw;
    }

    // ---------- primitives ----------
    static void writeVarInt(OutputStream o, int v) throws IOException {
        while ((v & ~0x7F) != 0) { o.write((v & 0x7F) | 0x80); v >>>= 7; }
        o.write(v);
    }
    static int readVarInt(InputStream in) throws IOException {
        int value = 0, pos = 0, b;
        while (true) {
            b = in.read();
            if (b == -1) throw new EOFException();
            value |= (b & 0x7F) << pos;
            if ((b & 0x80) == 0) break;
            pos += 7;
            if (pos >= 32) throw new IOException("VarInt too big");
        }
        return value;
    }
    static void writeString(OutputStream o, String s) throws IOException {
        byte[] b = s.getBytes("UTF-8");
        writeVarInt(o, b.length); o.write(b);
    }
    static void writeLong(OutputStream o, long v) throws IOException {
        for (int i = 7; i >= 0; i--) o.write((int)(v >>> (i*8)) & 0xFF);
    }
    static long readLong(InputStream in) throws IOException {
        long v = 0; for (int i = 0; i < 8; i++) { int b = in.read(); if (b<0) throw new EOFException(); v = (v<<8)|(b&0xFF); } return v;
    }
    static void writeInt(OutputStream o, int v) throws IOException {
        for (int i = 3; i >= 0; i--) o.write((v >>> (i*8)) & 0xFF);
    }
    static int readInt(InputStream in) throws IOException {
        int v = 0; for (int i = 0; i < 4; i++) { int b = in.read(); if (b<0) throw new EOFException(); v=(v<<8)|(b&0xFF);} return v;
    }
}
