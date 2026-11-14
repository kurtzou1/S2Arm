package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Map;

/** Cross-process receipt: a library Play may resume only the admitted live session, never retarget it. */
final class GameResume {
    static final String EXTRA = "s2arm.resume_session";
    private static File file(File cache) { return new File(cache, "game-active.json"); }

    static void publish(File cache, int pid, BootSpec spec) throws IOException {
        BootContract.Game game = spec.game;
        String json = "{\"pid\":" + pid + ",\"session\":\"" + spec.sessionId + "\",\"title\":\"" + game.titleId
            + "\",\"root\":\"" + game.contentRoot + "\",\"artifact\":\"" + game.artifactSha256 + "\"}";
        File temporary = new File(cache, "game-active.tmp");
        Files.write(temporary.toPath(), json.getBytes(StandardCharsets.UTF_8));
        Files.move(temporary.toPath(), file(cache).toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }

    static String requireSame(File cache, int pid, String title, File games) throws IOException, BootContract.BadGame {
        try {
            Map<String,Object> active = Json.object(Json.parse(new String(Files.readAllBytes(file(cache).toPath()), StandardCharsets.UTF_8)), "active game");
            BootContract.Current current = BootContract.readCurrent(new File(games, title));
            if (!(active.get("pid") instanceof Number) || ((Number)active.get("pid")).intValue() != pid
                    || !title.equals(active.get("title")) || !current.contentRoot.equals(active.get("root"))
                    || !current.artifactSha256.equals(active.get("artifact")) || !(active.get("session") instanceof String)
                    || ((String)active.get("session")).isEmpty())
                throw new IOException("previous :game owns a different revision/session");
            return (String)active.get("session");
        } catch (IllegalArgumentException error) { throw new IOException("invalid active game receipt", error); }
    }

    /** Title of the published active-game receipt, or null while none is readable (a game still starting has none yet). */
    static String activeTitle(File cache) {
        try {
            Object t = Json.object(Json.parse(new String(Files.readAllBytes(file(cache).toPath()), StandardCharsets.UTF_8)), "active game").get("title");
            return t instanceof String ? (String) t : null;
        } catch (IOException | RuntimeException error) { return null; }
    }

    static void clear(File cache) throws IOException { Files.deleteIfExists(file(cache).toPath()); }
}
