# DirectStuff — Encrypted R2 Video Host + Direct Download

Drop videos (`.mp4`, `.mov`, `.m4v`, `.webm`, `.mkv`, `.avi`) into `DirectStuff/`, and `upload.mjs` encrypts them locally with **AES-256-CTR**, uploads the ciphertext to **Cloudflare R2**, and outputs two links:
- **Watch + Download Page:** `/d/<id>?k=<key>` (video player + Download Video button)
- **Direct Download Link:** `/d/<id>/download?k=<key>` (downloads the decrypted video immediately)

Neither R2 nor KV ever stores the decryption key (`k` lives only in the shareable link).

## One-Time Setup
1. Create the R2 bucket & deploy the updated Worker from `backend/`:
   ```powershell
   cd backend
   npx wrangler r2 bucket create tinytiny-direct
   npx wrangler secret put DIRECT_UPLOAD_SECRET
   npx wrangler deploy
   ```
2. Copy `DirectStuff/.env.example` to `DirectStuff/.env` and set `DIRECT_UPLOAD_SECRET` to the same secret you entered above.

## Usage
- **Upload all videos currently in `DirectStuff/`:**
  ```powershell
  node DirectStuff/upload.mjs
  ```
- **Auto-watch `DirectStuff/` and upload any new video dropped in:**
  ```powershell
  node DirectStuff/upload.mjs --watch
  ```
- Saved links are also logged in `DirectStuff/links.txt` (gitignored), and uploaded originals are moved to `DirectStuff/uploaded/`.
