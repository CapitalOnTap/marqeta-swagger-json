# Marqeta Core API Swagger JSON

## Rationale

The Marqeta Core API adheres to the Open API (formerly Swagger) Specification version 2.0. Unfortunately the [Open API document](https://shared-sandbox-api.marqeta.com/v3/swagger.json) for the API isn't completely valid and produces some undesirable results when using code generators such as [swagger-codegen](https://github.com/RicoSuter/NSwag) or [NSwag](https://github.com/RicoSuter/NSwag).

## Current Status
| Official | Modified |
|----------|----------|
| <img src="http://online.swagger.io/validator?url=https://sandbox-api.marqeta.com/v3/swagger.json"> | <img src="http://online.swagger.io/validator?url=https://raw.githubusercontent.com/CapitalOnTap/marqeta-swagger-json/master/swagger.json"> |

## Usage
To use the modified version of the JSON file simply reference the [raw content for the file](https://raw.githubusercontent.com/CapitalOnTap/marqeta-swagger-json/master/swagger.json).

## Documentation

For complete reference documentation, see the [Marqeta Core API Reference](https://www.marqeta.com/api/docs/WYDH6igAAL8FnF21/api-introduction).

## Updating

In order to update the swagger.json file we need to first make a backup of our existing modified swagger file, then get the latest swagger from Marqeta, and then process it with adding custom modification in order for it to be in a state to work with the our code generator. If we ever need to add some custom modifications this is done in `./GetModifiedSwaggerJsonFile.ps1`. The process for updating is as follows:

- Back up current swagger json file: run `./Get-SwaggerJsonFileForArchive.ps1`
- Generate new swagger.json file: run `./GetModifiedSwaggerJsonFile.ps1`
- commit the updated swagger.json file and the added archive version. 