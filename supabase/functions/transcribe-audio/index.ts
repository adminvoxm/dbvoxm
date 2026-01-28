import { S3Client, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";
import { TranscribeClient, StartTranscriptionJobCommand, GetTranscriptionJobCommand } from "@aws-sdk/client-transcribe";

// Configuration CORS
const rawOrigins = Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "";
const allowedOrigins = rawOrigins.split(",").map((o) => o.trim());
const prodUrl = Deno.env.get("PROD_URL")!;

// Configuration AWS (On force le string car on sait qu'elles sont là)
const awsConfig = {
    region: Deno.env.get("AWS_REGION")!,
    credentials: {
        accessKeyId: Deno.env.get("AWS_ACCESS_KEY_ID")!,
        secretAccessKey: Deno.env.get("AWS_SECRET_ACCESS_KEY")!
    }
};

const bucketName = Deno.env.get("AWS_BUCKET_NAME")!;

Deno.serve(async (req) => {
    const origin = req.headers.get("origin") || "";
    
    // En-têtes CORS dynamiques
    const corsHeaders = {
        "Access-Control-Allow-Origin": allowedOrigins.includes(origin) ? origin : prodUrl,
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Credentials": "true",
        "Content-Type": "application/json"
    };

    // 1. Preflight OPTIONS
    if (req.method === "OPTIONS") {
        return new Response("OK", { status: 200, headers: corsHeaders });
    }

    // 2. Vérification méthode
    if (req.method !== "POST") {
        return new Response(JSON.stringify({ error: "Method Not Allowed" }), { 
            status: 405, 
            headers: corsHeaders 
        });
    }

    try {
        const body = await req.json().catch(() => null);
        if (!body || !body.audioUrl) {
            throw new Error("Body invalide ou 'audioUrl' manquant");
        }
        
        const { audioUrl } = body;

        // --- Init Clients AWS ---
        const s3 = new S3Client(awsConfig);
        const transcribe = new TranscribeClient(awsConfig);

        // --- 1️⃣ Télécharge le fichier depuis l'URL (Supabase ou autre) ---
        console.log(`Downloading audio from: ${audioUrl}`);
        const audioResponse = await fetch(audioUrl);
        if (!audioResponse.ok) throw new Error("Impossible de récupérer le fichier audio source");
        const audioBuffer = new Uint8Array(await audioResponse.arrayBuffer());

        // --- 2️⃣ Upload temporaire sur S3 ---
        const s3Key = `tmp/audio_${Date.now()}.mp3`;
        console.log(`Uploading to S3: ${s3Key}`);
        
        await s3.send(new PutObjectCommand({
            Bucket: bucketName,
            Key: s3Key,
            Body: audioBuffer,
            ContentType: "audio/mp3"
        }));

        const s3Url = `https://${bucketName}.s3.${awsConfig.region}.amazonaws.com/${s3Key}`;

        // --- 3️⃣ Lancement transcription ---
        const jobName = `transcribe_${Date.now()}`;
        console.log(`Starting transcription job: ${jobName}`);

        await transcribe.send(new StartTranscriptionJobCommand({
            TranscriptionJobName: jobName,
            LanguageCode: "fr-FR",
            MediaFormat: "mp3",
            Media: { MediaFileUri: s3Url }
        }));

        // --- 4️⃣ Polling (Attente active) ---
        let jobStatus = "IN_PROGRESS";
        let jobData = null;

        while (jobStatus === "IN_PROGRESS" || jobStatus === "QUEUED") {
            await new Promise((r) => setTimeout(r, 2000)); // Attendre 2s
            const result = await transcribe.send(new GetTranscriptionJobCommand({
                TranscriptionJobName: jobName
            }));
            
            jobStatus = result.TranscriptionJob?.TranscriptionJobStatus ?? "FAILED";
            jobData = result.TranscriptionJob;
        }

        // --- 5️⃣ Récupération texte ---
        let transcriptText = null;
        if (jobStatus === "COMPLETED" && jobData?.Transcript?.TranscriptFileUri) {
            console.log("Job completed, fetching transcript...");
            const transcriptRes = await fetch(jobData.Transcript.TranscriptFileUri);
            const transcriptJson = await transcriptRes.json();
            // Structure standard AWS Transcribe
            transcriptText = transcriptJson.results?.transcripts?.[0]?.transcript || "";
        } else {
            throw new Error(`Transcription failed with status: ${jobStatus}`);
        }

        // --- 6️⃣ Nettoyage S3 ---
        console.log("Cleaning up S3...");
        try {
            await s3.send(new DeleteObjectCommand({
                Bucket: bucketName,
                Key: s3Key
            }));
        } catch (cleanupErr) {
            console.error("Warning: Failed to delete S3 object", cleanupErr);
            // On ne bloque pas la réponse pour ça
        }

        // --- 7️⃣ Réponse succès ---
        return new Response(JSON.stringify({
            success: true,
            transcript: transcriptText,
            job: jobName
        }), {
            status: 200,
            headers: corsHeaders
        });

    } catch (err) {
        console.error("💥 Critical Error:", err);
        const errorMessage = err instanceof Error ? err.message : String(err);

        return new Response(JSON.stringify({
            success: false,
            error: errorMessage
        }), {
            status: 500,
            headers: corsHeaders
        });
    }
});