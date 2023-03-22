# JDWP Remapper

## The Problem

When developing Spigot plugins, one will often want to develop with Mojang's official mappings. However, the Spigot server runs on Spigot's mappings, and the class names and methods are all different. For plugins, Mojang mappings are converted to Spigot mappings during compilation, but this does not work for debugging, because the Java Debug Wire Protocol (JDWP) is text-based, and assumes that class names are the same both when developing and when running Java.

For example, if one sets a breakpoint at `net.minecraft.world.entity.monster.Zombie:263`, this will never be fired, because `Zombie` is the Mojang mapped name; the server only knows about `EntityZombie`, the spigot mapped name.

One solution to this problem is to use Mojang mappings on the server itself, which makes the debugger work, but does not work for plugins that are closely coupled to internal Minecraft code or use reflection.

Another solution is to debug using a decompiled Spigot mapped JAR. Placing breakpoints works and they trigger when expected, but the stack trace is very difficult to understand as the line numbers do not match up with line numbers in the decompiled code. The code is also much more unreadable as Spigot mappings are less comprehensive than Mojang mappings.

## The Solution

This CLI program acts as a TCP proxy for JDWP and allows you to place breakpoints on Mojang mapped code and it is translated to Spigot mapped code before being given to the Spigot server's JVM. The stack trace line numbers will also match up correctly.

### Usage

```
Usage: jdmap [OPTION]... <source jvm port> <listen proxy port> <mappings file>
Start a JDWP TCP proxy given the mappings file.
Example: jdmap -v -r 'org/bukkit/craftbukkit:org/bukkit/craftbukkit/v1_19_R1' 5005 5006 reobf.tiny

Options:
  -r, --remap      Separated by a colon, remap the first package on the proxy to the second package on the JVM.
  -v, --verbose    Output details of packets sent and received.
```

The `jvm port` is the port of the JVM which a debugger can connect to. The `proxy port` is the port that the remapper proxy will listen for and wait for a debugger to connect to. The `mappings file` is the file used for converting between Spigot and Mojang mappings. It can be found on a server in (for example) `versions/1.18.2/paper-1.18.2.jar` in `META-INF/mappings` under the name `reobf.tiny`, and starts with `tiny    2       0       mojang+yarn     spigot`.

### Development

This project is in a very early stage of development and only translates class names and allows you to place breakpoints. It does not translate method names yet, and there is very little configuration. Expect things to not work perfectly.
