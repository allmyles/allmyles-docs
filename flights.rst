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

.. _Flight_Search:

--------
 Search
--------

Request
=======

.. http:post:: /flights

    Searches for flights that match provided criteria.

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
        - **preferredAirlines** (*String\[ \]*) -- *(optional)* list of
          airlines to filter results to, given as their two character IATA code

.. _Person:

Person
------

    :JSON Parameters:
        - **passengerType** (*String*) -- one of :ref:`PassengerTypes`
        - **quantity** (*Integer*) -- number of travelers of ``passengerType``

Response
========

    :JSON Parameters:
        - **flightResultSet** (*:ref:`FlightResult`\[ \]*) -- root container

.. _FlightResult:

FlightResult
------------

    .. warning::
        The ``total_fare`` field here does not include the credit card
        surcharge just yet, as fetching the exact surcharge for a specific
        flight can require an extra 5-10 second call to the external provider.

        This surcharge is retrieved in the _`FlightDetails` call.

    :JSON Parameters:
        - **breakdown** (*:ref:`Breakdown`\[ \]*) -- summary of passenger data
          per type
        - **currency** (*String*) -- currency of all prices in response
        - **total_fare** (*Float*) -- total fare, including service fee
        - **combinations** (*:ref:`Combination`\[ \]*) -- list of combination
          objects

.. _Breakdown:

Breakdown
---------

    :JSON Parameters:
        - **fare** (*Float[ ]*) -- total price of the tickets for passengers of
          ``type``
        - **type** (*String*) -- type of passengers the breakdown is for, see
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of passengers of ``type``
        - **ticketDesignators** (*:ref:`TicketDesignator`\[ \]*) -- ticket
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
        - **flightSegments** (*:ref:`Segment`\[ \]*) -- The list of segments
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
        - **availableBookingClasses** (*BookingClass[ ]*) -- a list of the
          classes that can be booked for this specific segment

          - **cabinCode** (*String*) -- cabin code of the class
            (see :ref:`BookingClassCodes`)
          - **code** (*String*) -- code of the class
            (see :ref:`BookingClassCodes`)
          - **quantity** (*Integer*) -- amount of available seats for class

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
                        "availableBookingClasses": [
                          {
                            "cabinCode": "Y",
                            "code": "Y",
                            "quantity": 0
                          }
                        ]
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

.. http:get:: /flights/{bookingId}

    **bookingId** is the booking ID of the :ref:`Combination` to get the
    details of

Response
========

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
        - **baggageTiers** (:ref:`BaggageTier`) -- contains the different
          options the passenger has for bringing baggages along.
        - **fields** (:ref:`FormFields`) -- contains field validation data.
        - **price** (:ref:`Price`) -- contains the final price of the ticket
          (including the credit card surcharge, but not the baggages)
        - **result** (:ref:`FlightResult`) -- contains an exact copy of the
          result from the :ref:`Flight_Search` call's response
        - **options** (:ref:`FlightOptions`) -- contains whether certain
          options are enabled for this flight
        - **surcharge** (:ref:`Price`) -- contains the credit card surcharge
          for this flight

.. _BaggageTier:

BaggageTier
-----------

Not implemented currently. Estimated to be added during the week of May 19.

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
        - **currency** (*String*) -- the currency of the amount specified

.. _FlightOptions:

FlightOptions
-------------

    **{optionName}** below refers to the following names:

        - seatSelectionAvailable
        - travelfusionPrepayAvailable

    :JSON Parameters:
        - **{optionName}** (*Boolean*) -- whether the option is enabled or not


Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "flightDetails": {
            "rulesLink": null,
            "baggageTiers": [],
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
        - **passengers** (*:ref:`Passenger`\[ \]*) -- the list of passengers

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
        - **document** (:ref:`Document`) -- data about the identifying document
          the passenger wishes to travel with
        - **email** (*String*)
        - **namePrefix** (*String*) -- one of ``Mr``, ``Ms``, or ``Mrs``
        - **firstName** (*String*)
        - **lastName** (*String*)
        - **gender** (*String*) -- one of ``MALE`` or ``FEMALE``
        - **passengerTypeCode** (*String*) -- one of :ref:`PassengerTypes`

.. _Document:

Document
--------

    :JSON Parameters:
        - **id** (*String*) -- document's ID number
        - **dateOfExpiry** (*String*) -- format is YYYY-MM-DD
        - **issueCountry** (*String*) -- two letter code of issuing country
        - **type** (*String*) -- one of :ref:`DocumentTypes`

Response
========

    .. note::
        Again: **there's no response body for LCC book requests!**
        An HTTP 204 No Content status code confirms that Allmyles saved the
        sent data for later use.

    .. warning::
        The format of :ref:`Contact` and :ref:`FlightResult` objects contained
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
        - **flightData** (:ref:`FlightResult`) -- contains a copy of the
          result from the :ref:`Flight_Search` call's response


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
              "baggage": 0,
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
Allmyles gets the payment data. (In a later version this call will also allow
for immediate payments for traditional flights.)

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

Response
========

    **N/A:**

    Returns an HTTP 204 No Content status code if successful.

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

.. http:get:: /tickets/{bookingId}

    *bookingId** is the booking ID of the :ref:`Combination` to create a
    ticket for

Response
========

    As this is just an abstraction for the book call when buying an LCC ticket
    (there's no separate book and ticketing calls for those flights), the
    response differs greatly depending on whether the flight is traditional or
    LCC.

    :JSON Parameters for traditional flights:
        - **tickets** (*Ticket[ ]*) -- the purchased tickets

          - **passenger** (*String*) -- the name of the passenger the ticket
            was purchased for
          - **ticket** (*String*) -- the ticket number which allows the
            passenger to actually board the plane

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
        - **flightData** (:ref:`FlightResult`) -- contains a copy of the
          result from the :ref:`Flight_Search` call's response

Examples
========

Response
--------

    **JSON for traditional flights:**

    .. sourcecode:: json

        {
          "tickets": [
            {
              "passenger": "Mr Janos Kovacs",
              "ticket": "123-4567890123"
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
