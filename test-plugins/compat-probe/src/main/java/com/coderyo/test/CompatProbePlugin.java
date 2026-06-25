package com.coderyo.test;

import org.bukkit.Bukkit;
import org.bukkit.Location;
import org.bukkit.Material;
import org.bukkit.World;
import org.bukkit.block.Block;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.block.BlockBreakEvent;
import org.bukkit.event.entity.EntitySpawnEvent;
import org.bukkit.event.server.ServerLoadEvent;
import org.bukkit.plugin.java.JavaPlugin;

/**
 * Minimal real Bukkit plugin for P3.1 compat e2e. An UNMODIFIED, vanilla-style plugin
 * (no NMS, no coderyo APIs) that exercises the three compat-routed surfaces:
 *
 * <ul>
 *   <li>{@code onEnable} — logs (plugin lifecycle).</li>
 *   <li>An event {@link Listener} — handles {@link ServerLoadEvent} (global),
 *       {@link BlockBreakEvent} (block subject), {@link EntitySpawnEvent} (entity subject);
 *       on each, touches world state (reads/sets a block) + logs an observable line.</li>
 *   <li>A repeating sync scheduled task ({@code runTaskTimer}) that touches a world every
 *       few ticks — reads the highest block at a fixed location and logs it.</li>
 * </ul>
 *
 * Every observable action is logged with a {@code PROBE_*} marker so the e2e harness can
 * assert it ran, on a valid (tick) thread, without AsyncCatcher / sync-event errors.
 */
public final class CompatProbePlugin extends JavaPlugin implements Listener {

    private int taskRuns = 0;

    @Override
    public void onEnable() {
        getLogger().info("PROBE_ENABLE onEnable thread=" + Thread.currentThread().getName()
            + " primary=" + Bukkit.isPrimaryThread());
        Bukkit.getPluginManager().registerEvents(this, this);

        // Repeating sync task that touches a world every 20 ticks (1s). Touching world state
        // from a scheduled task is the classic single-main-thread expectation the compat layer
        // (Tier 0/2) must preserve under region.enabled=true.
        Bukkit.getScheduler().runTaskTimer(this, () -> {
            this.taskRuns++;
            final World world = Bukkit.getWorlds().isEmpty() ? null : Bukkit.getWorlds().get(0);
            if (world == null) {
                return;
            }
            // Touch world state: read the highest block Y at spawn (a real world read).
            final Location spawn = world.getSpawnLocation();
            final int highestY = world.getHighestBlockYAt(spawn);
            getLogger().info("PROBE_TASK run#" + this.taskRuns
                + " world=" + world.getName() + " highestY=" + highestY
                + " thread=" + Thread.currentThread().getName()
                + " primary=" + Bukkit.isPrimaryThread());
        }, 20L, 20L);
    }

    @Override
    public void onDisable() {
        getLogger().info("PROBE_DISABLE onDisable taskRuns=" + this.taskRuns);
    }

    /**
     * P3.2 Tier-1 driver command ({@code /probetier1}). Runs on the orchestrator main thread
     * (console/command dispatch happens between ticks, while regions are quiescent) and performs
     * <b>cross-region</b> block writes + reads via the <b>real Bukkit {@code Block} API</b>
     * ({@code World#getBlockAt(...).setType / getType}) — which funnels through
     * {@code CraftBlock.setBlockState / getBlockState}, the coderyoMC Tier-1 hook points.
     *
     * <p>Because the orchestrator does not own any region mid-tick, a write/read targeting a
     * forceloaded region resolves to an owning region the current thread does NOT own → the
     * Tier-1 marshal fires (void write → enqueue to the owning region; read → snapshot/marshal).
     * This is the cross-region path the no-players P3.1 test could not exercise. Coordinates are
     * passed in so the harness can target the two disjoint forceloaded regions.
     *
     * <p>Usage: {@code /probetier1 <x1> <y1> <z1> <x2> <y2> <z2>} — sets + reads a block in each
     * of two locations (expected to be in two different regions). All on the Bukkit API.
     */
    @Override
    public boolean onCommand(final CommandSender sender, final Command command,
                             final String label, final String[] args) {
        final World world = Bukkit.getWorlds().isEmpty() ? null : Bukkit.getWorlds().get(0);
        final String name = command.getName().toLowerCase(java.util.Locale.ROOT);
        if (!name.equals("probetier1") && !name.equals("probeverify")) {
            return false;
        }
        if (world == null) {
            getLogger().info("PROBE_TIER1 no-world");
            return true;
        }
        if (args.length < 6) {
            getLogger().info("PROBE_TIER1 usage: /" + name + " x1 y1 z1 x2 y2 z2");
            return true;
        }
        try {
            final int ax = Integer.parseInt(args[0]);
            final int ay = Integer.parseInt(args[1]);
            final int az = Integer.parseInt(args[2]);
            final int bx = Integer.parseInt(args[3]);
            final int by = Integer.parseInt(args[4]);
            final int bz = Integer.parseInt(args[5]);
            if (name.equals("probeverify")) {
                // READ-ONLY: confirm a previously-marshaled cross-region write actually LANDED
                // (drained at the owning region's tick). Pure Bukkit getType() -> Tier-1 read hook.
                getLogger().info("PROBE_VERIFY regionA landed=" + world.getBlockAt(ax, ay, az).getType()
                    + " @ " + ax + "," + ay + "," + az);
                getLogger().info("PROBE_VERIFY regionB landed=" + world.getBlockAt(bx, by, bz).getType()
                    + " @ " + bx + "," + by + "," + bz);
                return true;
            }
            setReadAt(world, "A", ax, ay, az, Material.LAPIS_BLOCK);
            setReadAt(world, "B", bx, by, bz, Material.REDSTONE_BLOCK);
        } catch (final NumberFormatException nfe) {
            getLogger().info("PROBE_TIER1 bad-args " + nfe.getMessage());
        }
        return true;
    }

    /** Bukkit-API write then read at one location — the Tier-1-hooked Craft* surface. */
    private void setReadAt(final World world, final String tag, final int x, final int y, final int z,
                           final Material material) {
        final Block b = world.getBlockAt(x, y, z);
        // WRITE via the Bukkit API -> CraftBlock.setBlockState -> Tier-1 void marshal hook.
        b.setType(material);
        // READ via the Bukkit API -> CraftBlock.getBlockState -> Tier-1 read hook.
        final Material got = b.getType();
        getLogger().info("PROBE_TIER1 region" + tag + " set=" + material + " readback=" + got
            + " @ " + x + "," + y + "," + z
            + " thread=" + Thread.currentThread().getName()
            + " primary=" + Bukkit.isPrimaryThread());
    }

    @EventHandler
    public void onServerLoad(final ServerLoadEvent event) {
        // Global event (no single owning location) -> Tier 2 legacy / orchestrator inline.
        // Set a block at a fixed location to prove world-mutation from an event handler works.
        final World world = Bukkit.getWorlds().isEmpty() ? null : Bukkit.getWorlds().get(0);
        String result = "no-world";
        if (world != null) {
            final Location spawn = world.getSpawnLocation();
            final Block b = world.getBlockAt(spawn.getBlockX(), world.getHighestBlockYAt(spawn) + 1, spawn.getBlockZ());
            b.setType(Material.GLOWSTONE);
            result = "set " + b.getType() + " @ " + b.getX() + "," + b.getY() + "," + b.getZ();
        }
        getLogger().info("PROBE_SERVERLOAD type=" + event.getType() + " " + result
            + " thread=" + Thread.currentThread().getName()
            + " primary=" + Bukkit.isPrimaryThread());
    }

    @EventHandler
    public void onBlockBreak(final BlockBreakEvent event) {
        // Block subject -> Tier 0 inline when on the owning region thread.
        final Block b = event.getBlock();
        getLogger().info("PROBE_BLOCKBREAK " + b.getType() + " @ " + b.getX() + "," + b.getY() + "," + b.getZ()
            + " thread=" + Thread.currentThread().getName()
            + " primary=" + Bukkit.isPrimaryThread());
    }

    @EventHandler
    public void onEntitySpawn(final EntitySpawnEvent event) {
        // Entity subject -> Tier 0 inline when on the owning region thread. Keep it cheap (count
        // only the first few to avoid log spam from natural spawning).
        if (event.getEntityType() == org.bukkit.entity.EntityType.ARMOR_STAND) {
            getLogger().info("PROBE_ENTITYSPAWN " + event.getEntityType()
                + " @ " + event.getLocation().getBlockX() + "," + event.getLocation().getBlockZ()
                + " thread=" + Thread.currentThread().getName()
                + " primary=" + Bukkit.isPrimaryThread());
        }
    }
}
