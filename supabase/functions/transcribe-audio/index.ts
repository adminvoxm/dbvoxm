import { S3Client, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";
import { TranscribeClient, StartTranscriptionJobCommand, GetTranscriptionJobCommand } from "@aws-sdk/client-transcribe";
import { serve } from "std/http/server.ts";

// Configuration CORS
const rawOrigins = Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "";
const allowedOrigins = rawOrigins.split(",").map((o) => o.trim());
const prodUrl = Deno.env.get("PROD_URL")!

serve(async (req) => {
    const origin = req.headers.get("origin") || "";
    
    // En-têtes CORS dynamiques
    const corsHeaders = {
        "Access-Control-Allow-Origin": allowedOrigins.includes(origin) ? origin : prodUrl,
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Credentials": "true",
        "Content-Type": "application/json"
    };

  // ⚠️ Gestion du preflight OPTIONS (obligatoire pour WeWeb)
  if (req.method === "OPTIONS") {
    return new Response("OK", {
      status: 200,
      headers: corsHeaders
    });
  }

  // 2. Vérification de la méthode (POST uniquement pour la logique)
    if (req.method !== "POST") {
        return new Response(JSON.stringify({ error: "Method Not Allowed" }), {
            status: 405,
            headers: corsHeaders
        });
    }

  try {
    const { audioUrl } = await req.json();
    if (!audioUrl) throw new Error("audioUrl manquant");
    // --- CONFIG AWS ---
    const region = Deno.env.get("AWS_REGION");
    const bucket = Deno.env.get("AWS_BUCKET_NAME");
    const accessKey = Deno.env.get("AWS_ACCESS_KEY_ID");
    const secretKey = Deno.env.get("AWS_SECRET_ACCESS_KEY");
    const s3 = new S3Client({
      region,
      credentials: {
        accessKeyId: accessKey,
        secretAccessKey: secretKey
      }
    });
    // --- 1️⃣ Télécharge le fichier Supabase ---
    const audioResponse = await fetch(audioUrl);
    if (!audioResponse.ok) throw new Error("Impossible de récupérer le fichier Supabase");
    const audioBuffer = new Uint8Array(await audioResponse.arrayBuffer());
    // --- 2️⃣ Upload temporaire sur S3 ---
    const s3Key = `tmp/audio_${Date.now()}.mp3`;
    await s3.send(new PutObjectCommand({
      Bucket: bucket,
      Key: s3Key,
      Body: audioBuffer,
      ContentType: "audio/mp3"
    }));
    const s3Url = `https://${bucket}.s3.${region}.amazonaws.com/${s3Key}`;
    // --- 3️⃣ Lancement transcription ---
    const transcribe = new TranscribeClient({
      region,
      credentials: {
        accessKeyId: accessKey,
        secretAccessKey: secretKey
      }
    });
    const jobName = `transcribe_${Date.now()}`;
    await transcribe.send(new StartTranscriptionJobCommand({
      TranscriptionJobName: jobName,
      LanguageCode: "fr-FR",
      MediaFormat: "mp3",
      Media: {
        MediaFileUri: s3Url
      }
    }));
    // --- 4️⃣ Attente fin du job ---
    let jobStatus = "IN_PROGRESS";
    let jobData = null;
    while(jobStatus === "IN_PROGRESS"){
      await new Promise((r)=>setTimeout(r, 5000));
      const result = await transcribe.send(new GetTranscriptionJobCommand({
        TranscriptionJobName: jobName
      }));
      jobStatus = result.TranscriptionJob?.TranscriptionJobStatus ?? "FAILED";
      jobData = result.TranscriptionJob;
    }
    // --- 5️⃣ Récupération texte ---
    let transcriptText = null;
    if (jobStatus === "COMPLETED") {
      const transcriptUrl = jobData.Transcript.TranscriptFileUri;
      const transcriptRes = await fetch(transcriptUrl);
      const transcriptJson = await transcriptRes.json();
      transcriptText = transcriptJson.results.transcripts[0].transcript;
    }
    // --- 6️⃣ Suppression du fichier S3 ---
    await s3.send(new DeleteObjectCommand({
      Bucket: bucket,
      Key: s3Key
    }));
    // --- 7️⃣ Retour du texte ---
    return new Response(JSON.stringify({
      success: jobStatus === "COMPLETED",
      transcript: transcriptText,
      job: jobName
    }), {
      headers: corsHeaders
    });
  } catch (err) {
    console.error("💥 Transcribe error:", err);
    
    // On vérifie si c'est une vraie erreur pour récupérer le message proprement
    const errorMessage = err instanceof Error ? err.message : String(err);

    return new Response(JSON.stringify({
      error: errorMessage
    }), {
      status: 500,
      headers: corsHeaders // Assure-toi que cette variable est bien définie plus haut
    });
  }
});
