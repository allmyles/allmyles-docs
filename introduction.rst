==============
 Introduction
==============

We highly recommend you to read at least :ref:`the 'Common Gotchas' section
below <common-gotchas>` before jumping into the API reference, as it contains
information about problems often encountered by developers working with our API
that are not immediately apparent.

----------------------------
 Reading This Documentation
----------------------------

For the most part, it should be rather easy to understand the documentation.
Two things that might require explanation are:

 - A colon in a URL path denotes a variable; in the path
   ``/flights/:booking_id`` the entirety of ``:booking_id`` should be replaced
   by a booking ID, as such: ``/flights/8986210d-7e2f-4481-a29f-846ab386ddac``

 - When declaring the type of a variable, the symbol ``[ ]`` after a type
   means that the variable's type is an array, containing items of the type
   named before the symbol.

   For example, a ``String [ ]`` variable can look like the following:
   ``["abc", "def", ""]``.

.. _common-gotchas:

----------------
 Common Gotchas
----------------

 - The staging API returns search results from all available airlines, but only
   the following results are guaranteed to work when booking in staging:

    - Budapest to London & London to Budapest British Airways flights, to filter
      for these, include ``"fromLocation": "BUD", "toLocation": "LON",
      "preferredAirlines": ["BA"]`` in your search request.
    - Budapest to London & London to Budapest Low Cost Carrier flights, to filter
      for these, include ``"fromLocation": "BUD", "toLocation": "LON",
      "providerType": "OnlyLowCost"`` in your search request.

 - Workflows expire 17 minutes after a search request arrives. Any requests for
   the same session will return an HTTP 412 error.

 - All requests in the booking flow are applied to the last received search
   request. This means that if a passenger is searching for flights in multiple
   tabs, they will be able to proceed with booking only in the tab they last
   searched in.

-----------------
 Request Headers
-----------------

In addition to standard HTTP headers, the following ones are of interest:

 - **Accept**: The format the response data should be sent in. Currently we
   support JSON, specified as ``application/json``, and XML, specified as
   ``application/json``.
 - **Cookie**: A unique identifier for the customer's session, this is typically
   the randomly generated session cookie saved on the customer's computer.
 - **X-Auth-Token**: The API key you received after signing up on
   `the Allmyles home page <https://allmyles.com>`_ (ex. ``12345678-1234``.)

------------------------
 Generic Response Codes
------------------------

The documentation has a number of different status codes listed as possible
reponses to certain requests that are specific to that response. In addition
to those, we can also return the following status codes:

 - **200 OK**: The request has succeeded.
 - **202 Accepted**: The request has been accepted for processing but the
   processing is not yet completed.
 - **301 Moved Permanently**: The resource at the endpoint URI has been moved
   permanently and the client must use the new address in the future.
 - **400 Bad Request**: Invalid request syntax, the error message will in most
   cases contain the exact reason. The client must not repeat the request in
   the same form.
 - **403 Forbidden**: The client failed to authorize themselves with a valid
   API key, and the request was rejected.
 - **404 Not Found**: Request contains an invalid URI endpoint, or the given
   resource does not exist.
 - **413 Rate Control**: Request limitation threshold violated.
 - **500 Internal Server Error**: The server has failed to complete the sent
   request---please report such errors to our support team at
   `support@allmyles.com <mailto:support@allmyles.com>`_!
 - **502 Bad Gateway**: The backend servers are down, or an update process
   is under way.
 - **503 Service Unavailable**: Servers are accessible, but overloaded.
   Try and repeat the request later.

--------------------
 Asynchronous Calls
--------------------

Long running requests, such as a flight search use asynchronous calls. This
means that the the Allmyles API can---and in most cases, will---respond to the
first request with an HTTP 202 status code, and no content. When this
happens, the client is expected to periodically send the same request to the
API, with a reasonable delay between the requests (5 seconds is a good baseline
for this.) The Allmyles API will then reply with an HTTP 202 response code if
processing is still underway, or any other status code and a content body if it
is done processing the request.

.. note::

  It is a good idea to implement a timeout on the client side that checks for
  infinite loops in this process, as the server theoretically could fail in a
  way that it won't stop returning 202 status codes.

-------------
 Quick Start
-------------

Configuration
=============

Create a localrc file with the following:

.. sourcecode:: bash

    #!/bin/bash
    SERVICE_ENDPOINT={ALLMYLES-API-URL-GOES-HERE}
    TENANT_KEY={YOUR-TENANTKEY-GOES-HERE}

Search Flights
==============

The following script starts a flight search, and then checks if a result is
available every 5 or so seconds.

.. sourcecode:: bash

    #!/bin/bash
    source localrc

    read -d '' PAYLOAD <<EOF
    {
        "fromLocation": "BUD",
        "toLocation": "LON",
        "departureDate": "$(date -v+7d -u +'%Y-%m-%dT%H:%M:%SZ')",
        "resultTypes": "default",
        "returnDate": "$(date -v+14d -u +'%Y-%m-%dT%H:%M:%SZ')",
        "persons": [
            {
                "passengerType": "ADT",
                "quantity": 1
            }
        ],
        "preferredAirlines": ["BA"]
    }
    EOF

    PAYLOAD=$(echo $PAYLOAD)

    echo "Sending search request..."
    while true
    do
        echo "Checking for search response..."
        STATUS=$(echo "$PAYLOAD" | curl $* \
            -s \
            -H "X-Auth-Token: $TENANT_KEY" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "Cookie: 12345678-02" \
            -d @- $SERVICE_ENDPOINT/flights \
            -w "%{http_code}" \
            -o /dev/null)
        if ( [ $STATUS == "200" ] )
        then
            break
        fi
        sleep 5
    done
    echo "Search response received!"

    RESPONSE=$(echo "$PAYLOAD" | curl $* \
        -H "X-Auth-Token: $TENANT_KEY" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Cookie: 12345678-02" \
        -d @- $SERVICE_ENDPOINT/flights)

    echo BOOKING_ID=$(echo $RESPONSE | sed -n 's/.*\"bookingId\": \"\([A-Za-z1-9\-_]*\)\".*/\1/p') >> localrc
    echo $RESPONSE

Get Flight Details
==================

.. sourcecode:: bash

    #!/bin/bash
    source localrc

    curl $* \
        -H "X-Auth-Token: $TENANT_KEY" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Cookie: 12345678-02" \
        $SERVICE_ENDPOINT/flights/$BOOKING_ID

Book a Flight
=============

.. sourcecode:: bash

    #!/bin/bash
    source localrc

    read -d '' PAYLOAD <<EOF
    {
        "bookingId": "$BOOKING_ID",
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
==================

.. sourcecode:: bash

    #!/bin/bash
    source localrc

    curl $* \
        -H "X-Auth-Token: $TENANT_KEY" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Cookie: 12345678-02" \
        $SERVICE_ENDPOINT/tickets/$BOOKING_ID
