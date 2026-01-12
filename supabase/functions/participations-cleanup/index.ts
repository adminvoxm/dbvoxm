import { createClient } from "@supabase/supabase-js";

// Définition de la structure de vos données (Typage fort)
interface ParticipationItem {
  target_id: string; // Nouveau nom
  target_file_url: string | null; // Nouveau nom
}

const BUCKET_NAME = "participations_files";

Deno.serve(async (_req) => { // Correction 1 : _req au lieu de req
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  // 1. Appel RPC
  const { data, error: fetchError } = await supabase.rpc(
    "get_participations_to_clean",
  );

  if (fetchError) {
    return new Response(JSON.stringify(fetchError), { status: 500 });
  }

  // On "cast" (force le type) des données reçues
  const items = data as ParticipationItem[] | null;

  if (!items || items.length === 0) {
    return new Response(JSON.stringify({ message: "Rien à nettoyer" }), {
      status: 200,
    });
  }

  // 2. Préparation
  const filePaths: string[] = [];
  const idsToUpdate: string[] = [];

  // Correction 2 : On utilise le type défini plus haut au lieu de 'any'
  items.forEach((item: ParticipationItem) => {
    idsToUpdate.push(item.target_id); // Ici c'est target_id maintenant

    if (item.target_file_url) { // Ici c'est target_file_url
      const urlParts = item.target_file_url.split(`${BUCKET_NAME}/`);
      if (urlParts.length > 1) {
        filePaths.push(urlParts[1]);
      }
    }
  });

  // 3. Suppression Storage
  if (filePaths.length > 0) {
    const { error: storageError } = await supabase.storage
      .from(BUCKET_NAME)
      .remove(filePaths);

    if (storageError) {
      console.error("Erreur suppression storage:", storageError);
    }
  }

  // 4. Update BDD
  const { data: statusData } = await supabase
    .from("status_generic")
    .select("id")
    .eq("technical_name", "delete")
    .single();

  const { error: updateError } = await supabase
    .from("participations")
    .update({
      personal_informations: null,
      message: null,
      file_url: null,
      transcription: null,
      gpdr_text: null,
      ip: null,
      device_id: null,
      status: statusData?.id,
    })
    .in("id", idsToUpdate);

  if (updateError) {
    return new Response(JSON.stringify(updateError), { status: 500 });
  }

  return new Response(
    JSON.stringify({
      message:
        `Nettoyage terminé. ${idsToUpdate.length} participations traitées.`,
    }),
    { status: 200 },
  );
});
