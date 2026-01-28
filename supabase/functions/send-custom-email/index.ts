import nodemailer from "nodemailer"; 

// --- GESTION CORS ET VARIABLES D'ENV ---

// Récupération et préparation des origines autorisées
const rawOrigins = Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "";
const allowedOrigins = rawOrigins.split(",").map((o) => o.trim());
const prodUrl = Deno.env.get("PROD_URL")!

// Identifiants SES
const SES_HOST = Deno.env.get("SES_SMTP_HOST"); 
const SES_USER = Deno.env.get("SES_SMTP_USER"); 
const SES_PASS = Deno.env.get("SES_SMTP_PASS"); 
const FROM_EMAIL = Deno.env.get("SES_FROM_EMAIL"); 

Deno.serve(async (req) => {
    const origin = req.headers.get("origin") || "";
    
    // Définition des en-têtes CORS dynamiques
    const corsHeaders = {
        "Access-Control-Allow-Origin": allowedOrigins.includes(origin) ? origin : prodUrl, // Utilise l'origine si elle est dans la liste, sinon "*" (si non trouvé)
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Credentials": "true"
    };

    // --- GESTION DES REQUÊTES ---

    // 1. Gestion de la requête Preflight CORS (OPTIONS)
    if (req.method === "OPTIONS") {
        return new Response("ok", {
            status: 200,
            headers: corsHeaders
        });
    }

    // 2. Vérification de la méthode (Seul POST est autorisé après OPTIONS)
    if (req.method !== "POST") {
        return new Response("Method Not Allowed", {
            status: 405,
            headers: corsHeaders
        });
    }

    // --- LOGIQUE D'ENVOI DE L'EMAIL (Méthode POST) ---

    try {

        
        const { to, subject, body } = await req.json();
        

        if (!to || !subject || !body) {
            return new Response(
                JSON.stringify({ error: "Missing required fields (to, subject, body)" }), 
                { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
            );
        }

        // Créer le transporteur Nodemailer (Identifiants SES)
        const transporter = nodemailer.createTransport({
            host: SES_HOST, 
            port: 587,      
            secure: false,  
            auth: {
                user: SES_USER,
                pass: SES_PASS
            }
        });

        // Envoi de l'email
        const info = await transporter.sendMail({
            from: FROM_EMAIL, 
            to: to,
            subject: subject,
            html: body,
        });

        console.log("Message sent: %s", info.messageId);

        // Réponse de succès (avec les en-têtes CORS)
        return new Response(
            JSON.stringify({ message: "Email sent successfully", messageId: info.messageId }),
            { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );

    } catch (error) {
        console.error("Email sending error:", error);

        // On sécurise le message : est-ce une vraie Erreur ou autre chose ?
        const errorMessage = error instanceof Error ? error.message : String(error);

        // Réponse d'erreur (avec les en-têtes CORS)
        return new Response(
            JSON.stringify({ error: "Failed to send email", details: errorMessage }),
            { 
                status: 500, 
                headers: { "Content-Type": "application/json", ...corsHeaders } 
            }
        );
    }
});