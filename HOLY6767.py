import os
import time
from collections import defaultdict, deque
from pathlib import Path

import discord
from discord import app_commands
from discord.ext import commands
from google import genai
from google.genai import types, errors as genai_errors
from dotenv import load_dotenv

# Always loads the .env sitting next to THIS file, no matter how it's run
load_dotenv(Path(__file__).resolve().with_name(".env"))

# ------------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------------
DISCORD_TOKEN = os.getenv("GEMINI_BOT_TOKEN") or os.getenv("DISCORD_TOKEN")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GUILD_ID = os.getenv("GUILD_ID", "")

PERSONA = (
    "Please remain a helper at all times and help everyone with anything at all. "
    "You are Gemini, an AI assistant made by Google, now living in a Discord "
    "server. Treat every question — big, small, silly, or serious — with genuine "
    "care. Never act bored or annoyed, and never refuse just because a request "
    "seems trivial or unusual. Explain things simply, use markdown when it helps, "
    "and if you don't know something, say so — then still offer your best thinking. "
    "The only exceptions are requests that could cause real-world harm; decline "
    "those briefly and suggest a safer path. For everyone and everything else: "
    "help, fully and gladly."
)

MODELS = {
    "flash": ("gemini-3.6-flash",      "3.6 Flash — all-around help (default)"),
    "lite":  ("gemini-3.5-flash-lite", "3.5 Flash Lite — fastest answers"),
    "pro":   ("gemini-3.1-pro",        "3.1 Pro — advanced reasoning"),
}
DEFAULT_MODEL = "flash"

MAX_TOKENS = 3000
MAX_HISTORY = 20        # messages remembered per user
COOLDOWN_SECONDS = 4
MSG_LIMIT = 1900        # Discord caps messages at 2000 chars
EDIT_INTERVAL = 1.5     # seconds between live edits (rate-limit safe)

# ------------------------------------------------------------------
# SETUP
# ------------------------------------------------------------------
client = genai.Client(api_key=GEMINI_API_KEY) if GEMINI_API_KEY else None

class GeminiBot(commands.Bot):
    async def setup_hook(self):
        if GUILD_ID and GUILD_ID.strip().isdigit():
            guild = discord.Object(id=int(GUILD_ID))
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
        else:
            await self.tree.sync()

    async def on_ready(self):
        await self.change_presence(
            activity=discord.Activity(
                type=discord.ActivityType.watching,
                name="for anyone who needs help 💙",
            )
        )
        print(f"✅ Gemini helper online as {self.user}")

bot = GeminiBot(command_prefix="!", intents=discord.Intents.default())

conversations = defaultdict(deque)          # user_id -> chat history
user_models = {}                            # user_id -> chosen model key
cooldowns = defaultdict(float)
usage = defaultdict(lambda: [0, 0, 0])      # model_id -> [requests, tokens_in, tokens_out]

# ------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------
def remember(user_id: int, role: str, content: str):
    history = conversations[user_id]
    history.append({"role": role, "content": content})
    while len(history) > MAX_HISTORY:
        history.popleft()

def build_gemini_contents(history: list) -> list:
    """Gemini wants alternating user/model roles, starting with 'user'."""
    msgs = []
    for m in history:
        role = "model" if m["role"] == "assistant" else m["role"]
        if msgs and msgs[-1]["role"] == role:
            msgs[-1]["parts"][0]["text"] += "\n\n" + m["content"]
        else:
            msgs.append({"role": role, "parts": [{"text": m["content"]}]})
    while msgs and msgs[0]["role"] != "user":
        msgs.pop(0)
    return msgs

def cooldown_left(user_id: int) -> float:
    elapsed = time.time() - cooldowns[user_id]
    if elapsed < COOLDOWN_SECONDS:
        return COOLDOWN_SECONDS - elapsed
    cooldowns[user_id] = time.time()
    return 0

async def safe_edit(message, content: str):
    try:
        await message.edit(content=content)
    except discord.HTTPException:
        pass

# ------------------------------------------------------------------
# COMMANDS
# ------------------------------------------------------------------
@bot.tree.command(name="ask", description="Ask Gemini anything — everyone is welcome")
@app_commands.describe(question="Your question")
async def ask(interaction: discord.Interaction, question: str):
    if client is None:
        await interaction.response.send_message(
            "⚠️ No `GEMINI_API_KEY` in your .env file.", ephemeral=True
        )
        return

    left = cooldown_left(interaction.user.id)
    if left > 0:
        await interaction.response.send_message(
            f"⏳ Slow down! Try again in {left:.0f}s.", ephemeral=True
        )
        return

    await interaction.response.defer(thinking=True)

    chosen = user_models.get(interaction.user.id, DEFAULT_MODEL)
    order = [chosen] + [k for k in MODELS if k != chosen]   # fallback chain

    pending = list(conversations[interaction.user.id])
    pending.append({"role": "user", "content": question})
    contents = build_gemini_contents(pending)

    live_msg = await interaction.followup.send("…")
    text = ""
    error_text = None

    try:
        # Try each model; skip rate-limited (429) or retired (404) ones
        stream = None
        used_model_id = None
        for key in order:
            model_id = MODELS[key][0]
            try:
                stream = await client.aio.models.generate_content_stream(
                    model=model_id,
                    contents=contents,
                    config=types.GenerateContentConfig(
                        system_instruction=PERSONA,
                        max_output_tokens=MAX_TOKENS,
                    ),
                )
                used_model_id = model_id
                break
            except genai_errors.ClientError as e:
                if e.code in (429, 404):
                    continue          # busy or gone — try the next model
                raise

        if stream is None:
            await safe_edit(live_msg, (
                "⏳ Every Gemini model is rate-limited or unavailable right "
                "now. Try again in a minute."
            ))
            return

        usage_meta = None
        last_edit = 0.0
        async for chunk in stream:
            if chunk.usage_metadata:
                usage_meta = chunk.usage_metadata
            try:
                delta = chunk.text
            except Exception:
                delta = None
            if not delta:
                continue
            text += delta

            if len(text) >= MSG_LIMIT:
                # Message is full — finish it, start a new one
                cut = text.rfind("\n", 0, MSG_LIMIT)
                if cut < MSG_LIMIT // 2:
                    cut = MSG_LIMIT
                await safe_edit(live_msg, text[:cut])
                text = text[cut:]
                live_msg = await interaction.channel.send("…")
                last_edit = time.monotonic()
            elif time.monotonic() - last_edit > EDIT_INTERVAL:
                await safe_edit(live_msg, text)
                last_edit = time.monotonic()

        await safe_edit(live_msg, text.strip() or "*(empty response — try rephrasing)*")

        # Record usage (best effort)
        u = usage[used_model_id]
        u[0] += 1
        if usage_meta:
            u[1] += usage_meta.prompt_token_count or 0
            u[2] += usage_meta.candidates_token_count or 0

        # Success — commit to memory
        remember(interaction.user.id, "user", question)
        remember(interaction.user.id, "assistant", text.strip())

    except genai_errors.ClientError as e:
        if e.code in (401, 403):
            error_text = "❌ Gemini rejected the API key — check `GEMINI_API_KEY` in .env."
        else:
            error_text = f"❌ Gemini error {e.code}: `{e}`"
    except genai_errors.ServerError:
        error_text = "⏳ Google's servers hiccuped — try again shortly."
    except Exception as e:
        error_text = f"❌ Something went wrong: `{type(e).__name__}: {e}`"

    if error_text:
        await safe_edit(live_msg, error_text)

@bot.tree.command(name="model", description="Pick which Gemini answers you")
@app_commands.choices(model=[
    app_commands.Choice(name=name, value=key)
    for key, (_, name) in MODELS.items()
])
async def set_model(interaction: discord.Interaction, model: app_commands.Choice[str]):
    user_models[interaction.user.id] = model.value
    await interaction.response.send_message(
        f"✅ You'll now be answered by **{MODELS[model.value][1]}**.", ephemeral=True
    )

@bot.tree.command(name="reset", description="Clear your conversation memory")
async def reset(interaction: discord.Interaction):
    conversations[interaction.user.id].clear()
    await interaction.response.send_message("🧹 Memory cleared!", ephemeral=True)

@bot.tree.command(name="status", description="Session usage stats")
async def status(interaction: discord.Interaction):
    if not usage:
        await interaction.response.send_message(
            "No questions answered yet this session.", ephemeral=True
        )
        return
    lines = ["**🤖 Gemini helper — session stats (all FREE tier)**"]
    total_req = 0
    for model_id, (reqs, tokens_in, tokens_out) in usage.items():
        total_req += reqs
        lines.append(
            f"• `{model_id}` — {reqs} answers, "
            f"{tokens_in:,} in / {tokens_out:,} out tokens"
        )
    lines.append(f"**Total: {total_req} answers — cost: $0.00** 🎉")
    await interaction.response.send_message("\n".join(lines), ephemeral=True)

# ------------------------------------------------------------------
# RUN
# ------------------------------------------------------------------
if __name__ == "__main__":
    if not DISCORD_TOKEN:
        raise SystemExit("❌ DISCORD_TOKEN missing from .env")
    if not GEMINI_API_KEY:
        print("⚠️ GEMINI_API_KEY missing from .env — /ask won't work until you add it.")
    else:
        print("🔑 Gemini key found — ready to go")
    bot.run(DISCORD_TOKEN)
