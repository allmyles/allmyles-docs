Allmyles API Quick Start
========================

Configuration
-------------

Create a localrc file with the following::

    #!/bin/bash
    SERVICE_ENDPOINT=https://api-testing.allmyles.com/v2.0
    TENANT_KEY={YOUR-TENANTKEY-GOES-HERE}

Search Flights
--------------

Send a search request::

    #!/bin/bash
    source localrc

    read -d '' PAYLOAD <<"EOF"
    {
        "fromLocation": "BUD",
        "toLocation": "LON",
        "departureDate": "2013-12-20T01:00:00Z",
        "resultTypes": "default",
        "returnDate": "2013-12-22T01:00:00Z",
        "persons": [
            {
                "passengerType": "ADT",
                "quantity": 1
            }
        ]
    }
    EOF
    echo "$PAYLOAD" | curl $* \
      -H "X-Auth-Token: $TENANT_KEY" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "Cookie: 12345678-02" \
      -d @- $SERVICE_ENDPOINT/flights

Book a Flight
-------------

Send a book request, replacing the bookingId with a valid one from the search
response from the previous step::

    #!/bin/bash
    source localrc

    read -d '' PAYLOAD <<"EOF"
    {
        "bookingId": "1/0",
        "passengers": [
            {
                "namePrefix": "MR",
                "firstName": "Lajos",
                "lastName": "Kovacs",
                "birthDate": "1911-01-01",
                "gender": "MALE",
                "passengerTypeCode": "ADT",
                "baggage": 0,
                "email": "aaa@gmail.com",
                "document": {
                    "type": "Passport",
                    "id": "123",
                    "issueCountry": "HU",
                    "dateOfExpiry": "2015-12-01"
                }
            }
        ],
        "contactInfo": {
            "name": "Kovacs Lajos",
            "address": {
                "countryCode": "HU",
                "cityName": "Budapest",
                "addressLine1": "Xasd utca 13."
            },
            "phone": {
                "countryCode": 36,
                "areaCode": 30,
                "phoneNumber": 1234567
            },
            "email": "lajos.kovacs@example.com"
        },
        "billingInfo": {
            "name": "Kovacs Lajos",
            "address": {
                "countryCode": "HU",
                "cityName": "Budapest",
                "addressLine1": "XBSD utca 23."
            }
        }
    }
    EOF
    echo "$PAYLOAD" | curl $* \
      -H "X-Auth-Token: $TENANT_KEY" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "Cookie: 12345678-02" \
      -d @- $SERVICE_ENDPOINT/books

Create Your Ticket
------------------

Send a ticket creation request. Make sure to replace the booking reference ID
with the one returned in the book response::

    #!/bin/bash
    source localrc

    curl $* \
      -H "X-Auth-Token: $TENANT_KEY" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "Cookie: 12345678-02" \
      $SERVICE_ENDPOINT/tickets/{booking_reference_id}
