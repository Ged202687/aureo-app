// Worker d'Auréo, devant les fichiers de l'application.
//
// Auréo ne s'utilise que depuis le plateau XGS (sauf pour un administrateur) :
// la regle est appliquee par le portail, qui le relaie sous /aureo/. Il ne
// doit donc pas etre joignable a sa propre adresse workers.dev, ni par les
// adresses d'apercu des versions (<version>-aureo-app.<compte>.workers.dev) :
// ces visites sont renvoyees vers le portail.
//
// Le portail, lui, appelle Auréo par sa liaison de service, sous un nom
// interne (aureo.interne) qu'aucun navigateur ne peut atteindre : ces
// requetes recoivent les fichiers normalement.

const PORTAIL = "https://portail-xgs.kgedeon.workers.dev";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname.endsWith(".workers.dev")) {
      return Response.redirect(`${env.PORTAIL_URL || PORTAIL}/aureo${url.pathname}${url.search}`, 302);
    }
    return env.ASSETS.fetch(request);
  },
};
