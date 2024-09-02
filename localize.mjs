// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import { readFile, writeFile } from "node:fs/promises";

const LOCALES = ["nl", "de", "it", "es"];
const OPENAI_KEY = process.env.OPENAI_KEY;
const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const OPENAI_MODEL = "gpt-4o-2024-08-06";

async function main() {
  const input = JSON.parse(await readFile("./Localizable.xcstrings"));

  const response_format = {
    type: "json_schema",
    json_schema: {
      name: "localizations",
      // strict: true,
      schema: {
        type: "object",
        required: LOCALES,
        additionalProperties: false,
        properties: Object.fromEntries(
          LOCALES.map((loc) => {
            return [
              loc,
              { type: "string", description: `translation to ${loc}` },
            ];
          })
        ),
      },
    },
  };

  for (const k in input.strings) {
    if (Object.hasOwnProperty.call(input.strings, k)) {
      const string = k;
      const locs = input.strings[k].localizations;
      const untranslatedLocales = LOCALES.filter((loc) => {
        return (
          !(loc in locs) ||
          !locs[loc].stringUnit ||
          !locs[loc].stringUnit.state === "translated"
        );
      });
      if (untranslatedLocales.length > 0) {
        const res = await fetch(OPENAI_URL, {
          method: "POST",
          headers: {
            "Content-type": "application/json",
            Authorization: `Bearer ${OPENAI_KEY}`,
          },
          body: JSON.stringify({
            model: OPENAI_MODEL,
            response_format,
            messages: [
              {
                role: "system",
                content:
                  `Translate the following English (en) text to the locales ${LOCALES.join(
                    ", "
                  )} returning ONLY a JSON object with the locales as key and the translation as value. The translation is ` +
                  `used in an iOS app for file synchronization. Use wording appropriate for iOS.`,
              },
              {
                role: "user",
                content: string,
              },
            ],
          }),
        });

        if (res.status !== 200) {
          console.error(res.statusText);
          console.log(await res.text());
          process.exit(-1);
        }

        const reply = await res.json();
        const translations = JSON.parse(reply.choices[0].message.content);
        console.log(string, translations);
        //process.exit(0);
        for (const ml of untranslatedLocales) {
          if (ml in translations) {
            input.strings[k].localizations[ml] = {
              stringUnit: { state: "translated", value: translations[ml] },
            };
          }
        }
      }
    }
  }

  await writeFile(
    "./Localizable.xcstrings",
    JSON.stringify(input, undefined, "  ")
  );
}

main();
