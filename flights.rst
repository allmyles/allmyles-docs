=========
 Flights
=========

---------
 Summary
---------

The flight booking/ticket creation workflow consists of four mandatory steps
for traditional flights. A fifth step (providing payment details) is required
when booking LCC flights.

 1. :ref:`Flight_Search`
 2. :ref:`Flight_Details`
 3. :ref:`Flight_Booking`
 4. :ref:`Flight_Payment` (mandatory only for LCC)
 5. :ref:`Flight_Ticketing`

Additional calls that are available:

 - :ref:`Flight_Rules`

.. _Flight_Search:

--------
 Search
--------

Request
=======

.. http:post:: /flights

    Searches for flights that match provided criteria.

    .. note::
        In most cases you'll want to pass 00:00:00 as time for both your
        departure and your return date. Time filtering constraints will be
        very strict otherwise, often resulting in no matches for your query.

    :JSON Parameters:
        - **fromLocation** (*String*) -- departure location, given as IATA code
        - **toLocation** (*String*) -- destination, given as IATA code
        - **departureDate** (*String*) -- date of departure, in ISO format,
          including a time code, even though whole day will be searched by
          default
        - **returnDate** (*String*) -- *(optional)* date of return, in ISO
          format, including a time code, even though whole day will be
          searched by default
        - **persons** (:ref:`Person`) -- a list of passengers, grouped by type
          code, containing Persons
        - **fromAirport** (*String*) -- *(optional)* departure airport, given
          as IATA code, must be in the city specified in ``fromLocation``
        - **toAirport** (*String*) -- *(optional)* destination airport, given
          as IATA code, must be in the city specified in ``toLocation``
        - **providerType** (*String*) -- *(optional)* type of results to
          retrieve
        - **preferredAirlines** (*String \[ \]*) -- *(optional)* list of
          airlines to filter results to, given as their two character IATA code

.. _Person:

Person
------

    :JSON Parameters:
        - **passengerType** (*String*) -- one of :ref:`PassengerTypes`
        - **quantity** (*Integer*) -- number of travelers of ``passengerType``

Response Body
=============

    :JSON Parameters:
        - **flightResultSet** (:ref:`flight-result` *\[ \]*) -- root container

.. _flight-result:

FlightResult
------------

    .. warning::
        The ``total_fare`` field here does not include the credit card
        surcharge just yet, as fetching the exact surcharge for a specific
        flight can require an extra 5-10 second call to the external provider.

        This surcharge is retrieved in the _`FlightDetails` call.

    :JSON Parameters:
        - **breakdown** (:ref:`Breakdown` *\[ \]*) -- summary of passenger data
          per type
        - **currency** (*String*) -- currency of all prices in response
        - **total_fare** (*Float*) -- total fare, including service fee
        - **combinations** (:ref:`Combination` *\[ \]*) -- list of combination
          objects

.. _Breakdown:

Breakdown
---------

    :JSON Parameters:
        - **fare** (*Float[ ]*) -- total price of the tickets for passengers of
          ``type`` (including tax)
        - **tax** (*Float[ ]*) -- total tax on the tickets for passengers of
          ``type``
        - **type** (*String*) -- type of passengers the breakdown is for, see
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of passengers of ``type``
        - **ticketDesignators** (:ref:`TicketDesignator` *\[ \]*) -- ticket
          designators applicable for passengers of ``type``

.. _TicketDesignator:

TicketDesignator
----------------

    Ticket designators are the mini-rules for the flight, with entries such as
    ``{"code": "70|PEN", "extension": "TICKETS ARE NON-REFUNDABLE|"}``.

    :JSON Parameters:
        - **code** (*String*) -- ticket designator's code
        - **extension** (*String*) -- ticket designator's description

.. _Combination:

Combination
-----------

    Combinations are the sets of different flight itineraries that can be
    booked. Every combination in a flight result is guaranteed to have the
    same total price, but the departure times, arrival times, and transfer
    locations can differ.

    .. note::
        As of May 2014, ``providerType`` can either be ``AmadeusProvider``, for
        traditional flights, or ``TravelFusionProvider``, for LCC flights.

    :JSON Parameters:
        - **providerType** (*String*) -- the provider the result is from
        - **bookingId** (*String*) -- the unique identifier of this
          combination (this is later used to identify the combination when
          booking, for example.)
        - **firstLeg** (:ref:`Leg`) -- The outbound leg of the itinerary
        - **returnLeg** (:ref:`Leg`) -- The inbound leg of the itinerary
        - **serviceFeeAmount** (*Float*) -- ticket designator's description

.. _Leg:

Leg
---

    Legs are made up of one or more segments, and span from one location the
    customer searched for to the other.

    :JSON Parameters:
        - **elapsedTime** (*String*) -- The total time between the leg's first
          departure, and last arrival (including time spent waiting when
          transferring). It is given in the format ``HHMM``.
        - **flightSegments** (:ref:`Segment` *\[ \]*) -- The list of segments
          this leg is made up of.

.. _Segment:

Segment
-------

    Segments are the smallest unit of an itinerary. They are the direct
    flights the passenger will take from one stop to another.

    :JSON Parameters:
        - **departure** (:ref:`Stop`) -- data about the flight's departure
        - **arrival** (:ref:`Stop`) -- data about the flight's arrival
        - **operatingAirline** (*String*) -- The airline operating this
          specific segment, given as a two character IATA code.
        - **availableSeats** (*Integer*) -- the number of seats available for
          this price tier---the maximum number we can know of is 9, so when 9
          is returned, that means 9 or more seats are available.
        - **cabin** (*String*) -- one of 'economy', 'first', or 'business'

.. _Stop:

Stop
----

    A stop is either the departure, or the arrival part of a segment.

    :JSON Parameters:
        - **dateTime** (*String*) -- time of the stop (in ISO format)
        - **airport** (*Airport*) -- location of the stop

          - **terminal** -- the relevant terminal of the airport specified
            below (this will be ``null`` is the airport has only one terminal)
          - **code** -- the three letter IATA code of the airport the stop is
            at

Response Codes
==============

 - **404 'No flights available'**
 - **404 'No flight found for return leg'**
 - **404 'Search does not include a required country'** - It is possible to set
   rules to disallow search queries that don't include a specific country in the
   itinerary. If a search request doesn't match the set filter, this is returned
 - **500 'external provider rejected the request - please try again'**: This is
   the generic error sent when we receive an unknown error as response from the
   provider

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "fromLocation": "BUD",
          "toLocation": "LON",
          "departureDate": "2014-05-15T00:00:00",
          "returnDate": "2014-05-20T00:00:00",
          "persons":[
            {
              "passengerType":"ADT",
              "quantity": 2
            },
            {
              "passengerType":"CHD",
              "quantity": 1
            }
          ]
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "flightResultSet": [
            {
              "breakdown": [
                {
                  "passengerFare": {
                    "fare": 52.8627,
                    "tax": 21.1229,
                    "ticketDesignators": [],
                    "type": "ADT",
                    "quantity": 1
                  }
                }
              ],
              "currency": "EUR",
              "total_fare": 57.8627,
              "combinations": [
                {
                  "providerType": "TravelFusionProvider",
                  "bookingId": "15_0_0",
                  "firstLeg": {
                    "elapsedTime": "0230",
                    "flightSegments": [
                      {
                        "arrival": {
                          "airport": {
                            "terminal": null,
                            "code": "STN"
                          },
                          "dateTime": "2014-06-05T23:00:00"
                        },
                        "operatingAirline": "FR",
                        "departure": {
                          "airport": {
                            "terminal": null,
                            "code": "BUD"
                          },
                          "dateTime": "2014-06-05T21:30:00"
                        },
                        "availableSeats": 9,
                        "cabin": "economy"
                      }
                    ]
                  },
                  "serviceFeeAmount": 5.0
                }
              ]
            }
          ]
        }

.. _Flight_Details:

---------
 Details
---------

Request
=======

.. http:get:: /flights/:booking_id

    **booking_id** is the booking ID of the :ref:`Combination` to get the
    details of

Response Body
=============

    :JSON Parameters:
        - **flightDetails** (:ref:`FlightDetailsContainer`) -- root container

.. _FlightDetailsContainer:

FlightDetails
-------------

    .. warning::
        While the ``price`` field contains the ticket's final price, baggages
        are not included in that, as the user may be able to choose from
        different baggage tiers. It is the travel site's responsibility to add
        the cost of the passenger's baggages themselves as an extra cost.

    .. note::
        Providers return prices in the travel site's preferred currency
        automatically. In the rare case that they might fail to do so, the
        Allmyles API will convert the prices to the flight fare's currency
        automatically, based on the provider's currency conversion data.

    :JSON Parameters:
        - **rulesLink** (*String*) -- link to the airline's rules page (hosted
          on the airline's website)
        - **baggageTiers** (:ref:`BaggageTier` *\[ \]*) -- contains the
          different options the passenger has for bringing baggages along
        - **fields** (:ref:`FormFields`) -- contains field validation data.
        - **price** (:ref:`Price`) -- contains the final price of the ticket
          (including the credit card surcharge, but not the baggages)
        - **result** (:ref:`flight-result`) -- contains an exact copy of the
          result from the :ref:`Flight_Search` call's response
        - **options** (:ref:`FlightOptions`) -- contains whether certain
          options are enabled for this flight
        - **surcharge** (:ref:`Price`) -- contains the credit card surcharge
          for this flight

.. _BaggageTier:

BaggageTier
-----------

    .. note::
        Keep in mind that while the tier ID's value may seem closely related to
        the other fields, it's not guaranteed to contain any semantic meaning at
        all.

    :JSON Parameters:
        - **tier** (*String*) -- the ID for this baggage tier (this is used to
          refer to it when booking)
        - **price** (:ref:`Price`) -- contains the price of the baggage tier
        - **max_weight** (*Float*) -- the maximum combined weight
          of all pieces of baggage a passenger can take in this tier, can be
          null if there's no limit
        - **max_quantity** (*Integer*) -- the maximum amount of pieces of
          baggage the passenger can take in this tier, can be null if there's
          no limit

.. _FormFields:

FormFields
----------

    **{fieldName}** below refers to the following names:

    .. hlist::
        :columns: 3

        - addressLine1
        - addressLine2
        - addressLine3
        - baggage
        - billingAddressLine1
        - billingAddressLine2
        - billingAddressLine3
        - billingCityName
        - billingCountryCode
        - billingZipCode
        - birthDate
        - cityName
        - countryCode
        - documentExpiryDate
        - documentId
        - documentIssuingCountry
        - documentType
        - email
        - firstName
        - gender
        - lastName
        - namePrefix
        - passengerTypeCode
        - phoneAreaCode
        - phoneCountryCode
        - phoneNumber
        - zipCode

    :JSON Parameters:
        - **{fieldName}** (*FormField*) -- Contains validation data for
          a field type

          - **required** (*Boolean*) -- Specifies whether the
          - **per_person** (*Boolean*) -- Contains field validation data.

    The different combinations of the values of `required` and `per_person`
    carry the following meaning:

    ======== ========== =======================================================
    required per_person meaning
    ======== ========== =======================================================
    True     True       Passing data for this field is mandatory for each
                        individual passenger.
    True     False      Passing data for this field is mandatory, but only for
                        the first passenger, or it requires a universal value
                        for the booking,such as `billingCityName`.
    False    True       Passing data for this field is not mandatory, but it
                        refers to something that can be different for each
                        passenger, such as `gender`.
    False    False      Passing data for this field is not mandatory, and it
                        refers to something that is universal for the booking,
                        such as `billingAddressLine3`.
    ======== ========== =======================================================

.. _Price:

Price
-----

    :JSON Parameters:
        - **amount** (*Float*) -- the amount of money in the currency below
        - **currency** (*String*) -- the currency of the amount specified, can
          be null when the amount is zero

.. _FlightOptions:

FlightOptions
-------------

    **{optionName}** below refers to the following names:

        - seatSelectionAvailable
        - travelfusionPrepayAvailable

    :JSON Parameters:
        - **{optionName}** (*Boolean*) -- whether the option is enabled or not

Response Codes
==============

 - **404 'search first'**
 - **412 'a request is already being processed'**: This error comes up even
   when the other request is asynchronous (i.e. when we are still processing a
   search request). The response for async requests does not need to be
   retrieved for this error to clear, just wait a few seconds.
 - **412 'request is not for the latest search'**: One case where this error
   is returned is when a customer is using multiple tabs and trying to select
   a flight from an old result list.

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "flightDetails": {
            "rulesLink": null,
            "baggageTiers": [
                {
                    "max_quantity": null,
                    "max_weight": 20.0,
                    "price": {
                        "amount": 0.0,
                        "currency": null
                    },
                    "tier": "1"
                },
                {
                    "max_quantity": 1,
                    "max_weight": null,
                    "price": {
                        "amount": 0.0,
                        "currency": null
                    },
                    "tier": "2"
                }
            ],
            "fields": {
              "countryCode": {
                "required": true,
                "per_person": false
              },
              "documentType": {
                "required": true,
                "per_person": true
              }
            },
            "price": {
              "currency": "EUR",
              "amount": 4464.46
            },
            "result": {
              "_comment": "trimmed in example for brevity's sake"
            },
            "options": {
              "seatSelectionAvailable": false,
              "travelfusionPrepayAvailable": false
            },
            "surcharge": {
              "currency": "EUR",
              "amount": 5.0
            }
          }
        }

.. _Flight_Booking:

---------
 Booking
---------

    .. note::
        When booking LCC flights, the Allmyles API does not send the book
        request to the external provider until the ticketing call arrives, so
        there's no response---an HTTP 204 No Content status code is returned.


Request
=======

.. http:post:: /books

    :JSON Parameters:
        - **bookingId** (*String*) -- the booking ID of the :ref:`Combination`
          to book
        - **billingInfo** (:ref:`Contact`) -- billing info for ticket creation
        - **contactInfo** (:ref:`Contact`) -- contact info for ticket creation
        - **passengers** (:ref:`Passenger` *\[ \]*) -- the list of passengers

.. _Contact:

Contact
-------

    :JSON Parameters:
        - **address** (:ref:`Address`) -- address of the entity in question
        - **email** (*String*) -- email of the entity in question
        - **name** (*String*) -- name of the entity in question
        - **phone** (:ref:`Phone`) -- phone number of the entity in question

.. _Address:

Address
-------

    :JSON Parameters:
        - **addressLine1** (*String*)
        - **addressLine2** (*String*) -- *(optional)*
        - **addressLine3** (*String*) -- *(optional)*
        - **cityName** (*String*)
        - **zipCode** (*String*)
        - **countryCode** (*String*) -- the two letter code of the country

.. _Phone:

Phone
-----

    :JSON Parameters:
        - **countryCode** (*Integer*)
        - **areaCode** (*Integer*)
        - **phoneNumber** (*Integer*)

.. _Passenger:

Passenger
---------

    :JSON Parameters:
        - **birthDate** (*String*) -- format is ``YYYY-MM-DD``
        - **document** (:ref:`FlightDocument`) -- data about the identifying
          document the passenger wishes to travel with
        - **email** (*String*)
        - **namePrefix** (*String*) -- one of ``Mr``, ``Ms``, or ``Mrs``
        - **firstName** (*String*)
        - **lastName** (*String*)
        - **gender** (*String*) -- one of ``MALE`` or ``FEMALE``
        - **passengerTypeCode** (*String*) -- one of :ref:`PassengerTypes`
        - **baggageTier** (*String*) -- one of the tier IDs returned in the
          flight details response

.. _FlightDocument:

Document
--------

    :JSON Parameters:
        - **id** (*String*) -- document's ID number
        - **dateOfExpiry** (*String*) -- format is YYYY-MM-DD
        - **issueCountry** (*String*) -- two letter code of issuing country
        - **type** (*String*) -- one of :ref:`DocumentTypes`

Response Body
=============

    .. note::
        Again: **there's no response body for LCC book requests!**
        An HTTP 204 No Content status code confirms that Allmyles saved the
        sent data for later use.

    .. warning::
        The format of :ref:`Contact` and :ref:`flight-result` objects contained
        within this response might slightly differ from what's described in
        this documentation as requested. This will be fixed in a later version.

    :JSON Parameters:
        - **pnr** (*String*) -- the PNR locator which identifies this booking
        - **lastTicketingDate** (*String*) -- the timestamp of when it's last
          possible to create a ticket for the booking, in ISO format
        - **bookingReferenceId** (*String*) -- the ID of the workflow at
          Allmyles; this is not currently required anywhere later, but can be
          useful for debugging
        - **contactInfo** (:ref:`Contact`) -- contains a copy of the data
          received in the :ref:`Flight_Booking` call
        - **flightData** (:ref:`flight-result`) -- contains a copy of the
          result from the :ref:`Flight_Search` call's response

Response Codes
==============

 - **303 'Unable to book this flight - please select a different bookingId'**:
   This error is returned when the external provider encounters a problem such
   as a discrepancy between actual flight data and what they returned from
   their cache before. This happens very rarely, or never in production.
 - **404 'search first'**
 - **412 'a request is already being processed'**: This error comes up even
   when the other request is asynchronous (i.e. when we are still processing a
   search request). The response for async requests does not need to be
   retrieved for this error to clear, just wait a few seconds.
 - **412 'Already booked.'**: This denotes that either us or the external
   provider has detected a possible duplicate booking, and has broken the flow
   to avoid dupe payments.
 - **412 'already booked'**: This is technically the same as the error above,
   but is encountered at a different point in the flow. The error messages are
   only temporarily not the same for these two errors.
 - **412 'request is not for the latest search'**
 - **500 'could not book flight'**: This is the generic error returned when we
   encounter an unknown/empty response from the external provider
 - **504 'external gateway timed out - book request might very well have been
   successful!'**: The booking might, or might not have been completed in this
   case. The flow should be stopped, and the customer should be contacted to
   complete the booking.
 - **504 'Could not retrieve virtual credit card, flight not booked. An IRN
   should be sent to payment provider now.'**

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "bookingId": "1_0_0",
          "billingInfo": {
            "address": {
              "addressLine1": "Váci út 13-14",
              "cityName": "Budapest",
              "countryCode": "HU",
              "zipCode": "1234"
            },
            "email": "ccc@gmail.com",
            "name": "Kovacs Gyula",
            "phone": {
              "areaCode": 30,
              "countryCode": 36,
              "phoneNumber": 1234567
            }
          },
          "contactInfo": {
            "address": {
              "addressLine1": "Váci út 13-14",
              "cityName": "Budapest",
              "countryCode": "HU"
            },
            "email": "bbb@gmail.com",
            "name": "Kovacs Lajos",
            "phone": {
              "areaCode": 30,
              "countryCode": 36,
              "phoneNumber": 1234567
            }
          },
          "passengers": [
            {
              "baggageTier": "0",
              "birthDate": "1974-04-03",
              "document": {
                "dateOfExpiry": "2016-09-03",
                "id": "12345678",
                "issueCountry": "HU",
                "type": "Passport"
              },
              "email": "aaa@gmail.com",
              "firstName": "Janos",
              "gender": "MALE",
              "lastName": "Kovacs",
              "namePrefix": "Mr",
              "passengerTypeCode": "ADT"
            }
          ]
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "bookingReferenceId": "req-cfd7963b187a4fe99702c0373c89cb16",
          "contactInfo": {
            "address": {
              "city": "Budapest",
              "countryCode": "HU",
              "line1": "Madach ut 13-14",
              "line2": null,
              "line3": null
            },
            "email": "testy@gmail.com",
            "name": "Kovacs Lajos",
            "phone": {
              "areaCode": 30,
              "countryCode": 36,
              "number": 1234567
            }
          },
          "flightData": {
            "_comment": "trimmed in example for brevity's sake"
          },
          "lastTicketingDate": "2014-05-16T23:59:59Z",
          "pnr": "6YESST"
        }

.. _Flight_Payment:

---------
 Payment
---------

If payment is required---that is, if the flight is an LCC one---this is where
Allmyles gets the payment data.

The only supported payment provider at the moment is PayU. When we receive a
transaction ID that points to a successful payment by the passenger, we
essentially take that money from PayU, and forward it to the provider to buy a
ticket in the :ref:`Flight_Ticketing` step.

Request
=======

.. http:post:: /payment

    :JSON Parameters:
        - **payuId** (*String*) -- the transaction ID identifying the
          successful transaction at PayU

Response Body
=============

    **N/A:**

    Returns an HTTP 204 No Content status code if successful.

Response Codes
==============

 - **412 'a request is already being processed'**: This error comes up even
   when the other request is asynchronous (i.e. when we are still processing a
   search request). The response for async requests does not need to be
   retrieved for this error to clear, just wait a few seconds.
 - **412 'book request should have been received'**

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "payuId": "12345678"
        }

.. _Flight_Ticketing:

-----------
 Ticketing
-----------

Two important notes:

1. Call this only when the passenger's payment completely went through! (That
   is, after the payment provider's IPN has arrived, confirming that the
   transaction did not get caught by the fraud protection filter.)
2. After this call has been made **do not issue refunds** unless the Allmyles
   API explicitly tells you to. It's way better to just correct ticketing
   errors manually than to fire automatic refunds even if the ticket purchase
   might already be locked in for some reason.

Request
=======

.. http:get:: /tickets/:booking_id

    *bookingId** is the booking ID of the :ref:`Combination` to create a
    ticket for

Response Body
=============

    As this is just an abstraction for the book call when buying an LCC ticket
    (there's no separate book and ticketing calls for those flights), the
    response differs greatly depending on whether the flight is traditional or
    LCC.

    :JSON Parameters for traditional flights:
        - **tickets** (*Ticket [ ]*) -- the purchased tickets

          - **passenger** (*String*) -- the name of the passenger the ticket
            was purchased for
          - **ticket** (*String*) -- the ticket number which allows the
            passenger to actually board the plane
          - **price** (*TicketPrice*)

            - **currency** (*String*)
            - **total_fare** (*Float*) -- The total amount of money the
              passenger paid for his ticket, including tax.
            - **tax** (*Float*) -- The total amount of tax the passenger had to
              pay for this ticket.

    :JSON Parameters for LCC flights:
        - **ticket** (*String*) -- the ticket number (LCC PNR) for this booking
        - **pnr** (*String*) -- the PNR locator which identifies this booking
        - **lastTicketingDate** (*String*) -- the timestamp of when it's last
          possible to create a ticket for the booking, in ISO format
        - **bookingReferenceId** (*String*) -- the ID of the workflow at
          Allmyles; this is not currently required anywhere later, but can be
          useful for debugging
        - **contactInfo** (:ref:`Contact`) -- contains a copy of the data
          received in the :ref:`Flight_Booking` call
        - **flightData** (:ref:`flight-result`) -- contains a copy of the
          result from the :ref:`Flight_Search` call's response

Response Codes
==============

 - **202 'Warning: e-ticket could not be issued due to technical difficulties.
   Please contact youragent.'**: When this error occurs, the actual ticket is
   purchased, but an unknown error happens later on in the flow.
 - **412 'a request is already being processed'**: This error comes up even
   when the other request is asynchronous (i.e. when we are still processing a
   search request). The response for async requests does not need to be
   retrieved for this error to clear, just wait a few seconds.
 - **412 'no payment data given'**
 - **412 'book request should have been received'**
 - **412 'book response should have been received'**
 - **500 'booking failed, cannot create ticket'**: This error is returned if
   the book response we last received from the provider contained an error.
 - **503 'error while querying PNR - please try again later'**: This error is
   returned when we are not able to check the PNR for the booking, prior to
   actually creating a ticket. Safe to refund.
 - **504 'PNR query timed out - please try again later'**: This is almost the
   same as the one above, also safe to refund.
 - **503 'error while creating ticket - please try again later'**: This is the
   generic error we return when receiving an unknown response for the ticket
   request. No refund should be sent without manually checking if the ticket
   has been issued first.
 - **504 'ticket creation timed out - but could very well have been
   successful!'**: Almost the same as above, refunds are definitely not safe in
   this case.

Examples
========

Response
--------

    **JSON for traditional flights:**

    .. sourcecode:: json

        "body": {
          "tickets": [
            {
              "passenger": "Mr Janos kovcas",
              "ticket": "125-4838843038",
              "price": {
                "currency": "HUF",
                "total_fare": 26000.0,
                "tax": 17800.0
              }
            },
            {
              "passenger": "Mr Janos kascvo",
              "ticket": "125-4838843039",
              "price": {
                "currency": "HUF",
                "total_fare": 26000.0,
                "tax": 17800.0
              }
            }
          ]
        }

    **JSON for LCC flights:**

    .. sourcecode:: json

        {
          "bookingReferenceId": "req-d65c00dc43ba4ad798e5478803575aab",
          "contactInfo": {
            "address": {
              "city": "Budapest",
              "countryCode": "HU",
              "line1": "Madach ut 13-14",
              "line2": null,
              "line3": null
            },
            "email": "testytesty@gmail.com",
            "name": "Kovacs Lajos",
            "phone": {
              "areaCode": 30,
              "countryCode": 36,
              "number": 1234567
            }
          },
          "flightData": {
            "_comment": "trimmed in example for brevity's sake"
          },
          "lastTicketingDate": null,
          "pnr": "6YE2LM",
          "ticket": "0XN4GTO"
        }

.. _Flight_Rules:

-------
 Rules
-------

This call returns the terms and conditions of the flight in question, or a link
to them if the raw text isn't available (in case of LCC flights).

Request
=======

.. http:get:: /flights/:booking_id/rules

    **booking_id** is the booking ID of the :ref:`Combination` to get the
    rules of

Response Body
=============

    :JSON Parameters:
        - **rulesResultSet** (*RulesResultSet*) -- root container

          - **rules** (:ref:`Rule` *\[ \]*) -- contains the flight rule texts,
            is returned only for traditional flights
          - **link** (*String*) -- contains a link to the airline's rules
            page, is returned only for LCC flights

.. _Rule:

Rule
----

    :JSON Parameters:
        - **code** (*String*) - the machine readable identifier code for the
          given section in the rules
        - **title** (*String*) - the human readable section title for the block
        - **text** (*String*) - the section's raw rule text body

Response Codes
==============

 - **404 'search first'**
 - **412 'a request is already being processed'**: This error comes up even
   when the other request is asynchronous (i.e. when we are still processing a
   search request). The response for async requests does not need to be
   retrieved for this error to clear, just wait a few seconds.
 - **409 'request is not for the latest search'**

Examples
========

Response
--------

    **JSON (for LCC):**

    .. sourcecode:: json

        {
          "rulesResultSet": {
            "link": "https://www.ryanair.com/en/terms-and-conditions"
          }
        }

    **JSON (for traditional):**

    .. sourcecode:: json

        {
          "rulesResultSet": {
            "rules": [
              {
                "code": "OD",
                "text": "NONE UNLESS OTHERWISE SPECIFIED",
                "title": "OTHER DISCOUNTS"
              },
              {
                "code": "SO",
                "text": "STOPOVERS NOT PERMITTED ON THE FARE COMPONENT.",
                "title": "STOPOVERS"
              },
            ]
          }
        }
