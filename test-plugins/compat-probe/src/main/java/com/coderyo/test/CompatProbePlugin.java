package com.coderyo.test;

import org.bukkit.Bukkit;
import org.bukkit.Location;
import org.bukkit.Material;
import org.bukkit.World;
import org.bukkit.block.Block;
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
