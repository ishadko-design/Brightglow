import { assertEquals } from "jsr:@std/assert@1";
import { brandDomain, collapseFranchises } from "./franchise.ts";

Deno.test("brandDomain strips www, path and query; ignores shared hosts", () => {
  assertEquals(brandDomain("https://www.miraclemethod.com/san-jose?utm_source=gmb"), "miraclemethod.com");
  assertEquals(brandDomain("http://miraclemethod.com/sonoma-marin"), "miraclemethod.com");
  assertEquals(brandDomain("https://www.facebook.com/somebiz"), "");
  assertEquals(brandDomain("https://joe.business.site/"), "");
  assertEquals(brandDomain(undefined), "");
});

Deno.test("collapseFranchises keeps the nearest sibling, leaves others alone", () => {
  const here = { lat: 37.6879, lng: -122.4702 }; // Daly City
  const places = [
    { id: "pacheco", websiteUri: "https://www.miraclemethod.com/alameda-contra-costa", location: { latitude: 38.0, longitude: -122.08 } },
    { id: "a1", websiteUri: "https://a1qualityrefinishing.com/", location: { latitude: 37.8, longitude: -121.99 } },
    { id: "brisbane", websiteUri: "https://www.miraclemethod.com/san-francisco", location: { latitude: 37.68, longitude: -122.4 } },
    { id: "fb", websiteUri: "https://facebook.com/x" },
    { id: "fb2", websiteUri: "https://facebook.com/y" },
  ];
  assertEquals(collapseFranchises(places, here.lat, here.lng).map((p) => p.id), ["a1", "brisbane", "fb", "fb2"]);
});
