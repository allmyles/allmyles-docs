========
 Hotels
========

---------
 Summary
---------

The hotel booking workflow consists of three mandatory steps.

 1. :ref:`Hotel_Search`
 2. :ref:`Hotel_Details`
 3. :ref:`Hotel_Booking`

Additional calls that are available:

 - :ref:`Hotel_Room_Details`

.. _Hotel_Search:

--------
 Search
--------

Request
=======

.. http:post:: /hotels

    Searches for hotels that match provided criteria.

    :JSON Parameters:
        - **cityCode** (*String*) -- city to search for a hotel in, given as
          its IATA code
        - **arrivalDate** (*String*) -- date when the occupants arrive, in ISO
          format, not including a time code (ex. 2014-12-24)
        - **leaveDate** (*String*) -- date when the occupants arrive, in ISO
          format, not including a time code (ex. 2014-12-26)
        - **occupancy** (*Integer*) -- number of people wanting to book a room

Response Body
=============

    :JSON Parameters:
        - **hotelResultSet** (:ref:`hotel-result` *\[ \]*) -- root container

.. _hotel-result:

Hotel
-----

    :JSON Parameters:
        - **hotel_id** (*String*) --
        - **hotel_name** (*String*) --
        - **chain_name** (*String*) --
        - **amenities** (*Amenities*) -- An associative array mapping each
          amenity listed below to a boolean value based on whether the hotel
          has given amenity. List of keys: 'restaurant', 'bar', 'laundry',
          'room_service', 'safe_deposit_box', 'parking', 'swimming',
          'internet', 'gym', 'air_conditioning', 'business_center',
          'meeting_rooms', 'spa', 'pets_allowed'
        - **latitude** (*Float*) -- The latitude component of the coordinates
          of the hotel
        - **longitude** (*Float*) -- The latitude component of the coordinates
          of the hotel
        - max_rate (*Price*)

           - amount (*Float*) --
           - currency (*String*) --
        - min_rate (*Price*) --

           - amount (*Float*) --
           - currency (*String*) --
        - stars (*Integer*) -- The amount of stars the hotel has been awarded
        - thumbnail (*String*) -- Link to a small image representing the hotel

Response Codes
==============

 - **404 'No hotels available'**

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "cityCode": "LON",
          "occupancy": 1,
          "arrivalDate": "2014-09-29",
          "leaveDate": "2014-09-30"
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

      {
        "hotelResultSet": [
          {
            "amenities": {
              "air_conditioning": false,
              "bar": true,
              "business_center": false,
              "gym": false,
              "internet": false,
              "laundry": false,
              "meeting_rooms": true,
              "parking": true,
              "restaurant": false,
              "room_service": false,
              "safe_deposit_box": true,
              "spa": true,
              "swimming": false
            },
            "chain_name": "ACCOR HOTELS",
            "hotel_id": "12_2",
            "hotel_name": "MERCURE PARIS PLACE ITALIE 3*",
            "latitude": 48.8303,
            "longitude": 2.35283,
            "max_rate": {
              "amount": 21951.12,
              "currency": "HUF"
            },
            "min_rate": {
              "amount": 18024.3,
              "currency": "HUF"
            },
            "stars": 3,
            "thumbnail": "https://static.allmyles.com/hotels/e4ba87c0/12_2.jpg"
          }
        ]
      }

.. _Hotel_Details:

---------
 Details
---------

Request
=======

.. http:get:: /hotels/:hotel_id

    **hotel_id** is the ID of the :ref:`hotel-result` to get the details of

Response Body
=============

    :JSON Parameters:
        - **hotel_details** (:ref:`HotelDetailsContainer`) -- root container

.. _HotelDetailsContainer:

HotelDetails
------------

    :JSON Parameters:
        - **chain_code** (*String*) --
        - **chain_name** (*String*) --
        - **hotel_code** (*String*) --
        - **hotel_name** (*String*) --
        - **location** (:ref:`HotelLocation`) -- contains info about the
          hotel's location.
        - **points_of_interest** (:ref:`POI` *\[ \]*) -- contains a list
          of notable locations around the hotel
        - **description** (*String*) -- A short text describing the hotel
        - **contact_info** (*HotelContactInfo*) --

          - **phone_numbers** (*String \[ \]*) --
          - **email** (*String*) --
          - **website** (*String*) --
        - **price** (*PriceRange*) -- contains the lowest and highest rates
          available for a room at this hotel

          - **minimum** (*Float*) -- Rate of the cheapest room at the hotel
          - **maximum** (*Float*) -- Rate of the most expensive room at the
            hotel
          - **currency** (*String*) --
        - **thumbnail** (*String*) -- Contains a URL pointing to a small
          image of the hotel
        - **photos** (*String \[ \]*) -- Contains an array of URLs pointing
          to a larger photos of the hotel
        - **amenities** (*Amenities*) -- Contains an associative array,
          mapping each amenity listed below to a boolean value based on
          whether the hotel has given amenity. List of keys: 'restaurant',
          'bar', 'laundry', 'room_service', 'safe_deposit_box', 'parking',
          'swimming', 'internet', 'gym', 'air_conditioning',
          'business_center', 'meeting_rooms', 'spa', 'pets_allowed'
        - **stars** (*Integer*) -- Contains the amount of stars this hotel
          has been awarded.
        - **rules** (*Rules*) -- Contains an associative array, mapping each
          rule type listed below to the relevant text. List of keys:
          'guarantee', 'safety', 'extra_occupants', 'policy', 'charges',
          'deposit', 'meals', 'stay', 'tax'
        - **rooms** (:ref:`Room` *\[ \]*) -- contains the available rooms

.. _HotelLocation:

HotelLocation
-------------

    :JSON Parameters:
        - **country** (*String*) --
        - **state** (*String*) --
        - **city** (*String*) --
        - **address** (*String*) --
        - **zip_code** (*String*) --
        - **area** (*String*) -- one of: 'north', 'east', 'south', 'west',
          'downtown', 'airport', 'resort'
        - **recommended_transport** (*String*) -- one of: 'boat', 'coach',
          'train', 'free', 'helicopter', 'limousine', 'plane', 'rental car',
          'taxi', 'subway', 'walking'

.. _Room:

Room
----

    :JSON Parameters:
        - **room_id** (*String*) -- ID of the room in question
        - **booking_id** (*String*) -- ID to use when booking this room
        - **price** (*RoomPrice*) -- Contains data about the price of the room

          - **amount** (*Float*) --
          - **covers** (*String*) -- One of 'day' or 'trip', specifies which
            duration the price covers
          - **rate_varies** (*Boolean*) -- True if the rate is not going to be
            the same for each day during the occupant's stay. In this case,
            the above given amount is the highest one during the trip.
        - **room_type** (*Traits*) -- Contains the traits of the given room,
          including the category, bed/shower availability, whether smoking is
          allowed, and whether it is a suite. The keys are the following:
          'bath', 'shower', 'nonsmoking', 'suite', 'category'. The first four
          have boolean values, while 'category' can be one of: 'minimum',
          'standard', 'moderate', 'superior', 'executive'
        - **bed_type** (*String*) -- One of: 'single', 'double', 'twin',
          'king size', 'queen size', 'pullout', 'water bed'
        - **description** (*String*) -- Contains a short text about the room
        - **quantity** (*Integer*) -- Contains the amount left to be booked of
          this room

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

      {
        "hotel_details": {
          "amenities": {
            "air_conditioning": false,
            "bar": true,
            "business_center": false,
            "gym": true,
            "internet": false,
            "laundry": false,
            "meeting_rooms": true,
            "parking": true,
            "restaurant": false,
            "room_service": false,
            "safe_deposit_box": true,
            "spa": true,
            "swimming": false
          },
          "category": "tourist",
          "chain_code": "RT",
          "chain_name": "ACCOR HOTELS",
          "contact_info": {
            "phone_numbers": [
              "33/1/40851919",
              "33/1/40859900"
            ]
          },
          "description": "the ibis paris gennevilliers hotel boasts an ideal location just outside paris just a stone's throw away from the les agnettes metro stop, you'll find yourself in the center of paris in just over 15 minutes this 3-star hotel has everything you need foran enjoyable stay: fully equipped rooms, gourmet restaurant, 24-hour bar, conference rooms and an ideal location with shops nearby and a shopping center opposite the hotel.",
          "hotel_code": "GVL",
          "hotel_name": "Ibis paris gennevilliers.",
          "location": {
            "address": "32 36 rue louis calmel.",
            "area": "downtown",
            "city": "PAR",
            "country": "FR",
            "recommended_transport": "taxi",
            "state": "",
            "zip_code": "92230"
          },
          "photos": [
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_EXT_01.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_EXT_02.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_LOUNGE_01.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_LOUNGE_02.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_REST_01.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_REST_02.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_CONF_01.jpg",
            "https://static.allmyles.com/hotels/81bf3a6c/55_0_REC_01.jpg"
          ],
          "points_of_interest": {
            "airports": [
              {
                "airport_code": "CDG",
                "airport_name": "CHARLES DE GAULLE",
                "direction": "NE",
                "distance": "14.9",
                "unit": "MI"
              },
              {
                "airport_code": "ORY",
                "airport_name": "ORLY",
                "direction": "S",
                "distance": "21.7",
                "unit": "MI"
              }
            ],
            "city_center": {
              "distance": "0.4",
              "unit": "MI"
            },
            "miscellaneous": [
              {
                "direction": "NE",
                "distance": "1.8",
                "name": "EIFFEL TOWER",
                "type": "tourist",
                "unit": "KM"
              },
              {
                "direction": "W",
                "distance": "1.0",
                "name": "LE LOUVRE",
                "type": "tourist",
                "unit": "KM"
              }
            ]
          },
          "price": {
            "currency": "HUF",
            "maximum": 20308.52,
            "minimum": 14634.08
          },
          "rooms": [
            {
              "bed_type": "twin",
              "booking_id": "55_0/85_0",
              "description": "STANDARD ROOM WITH 2 SINGLE BEDS",
              "price": {
                "amount": 14634.08,
                "covers": "trip",
                "rate_varies": false
              },
              "quantity": 2,
              "room_id": "85_0",
              "room_type": {
                "bath": true,
                "category": "standard",
                "nonsmoking": false,
                "shower": true,
                "suite": false
              }
            }
          ],
          "rules": {
            "charges": "FAX CHARGE: -INCOMING FAX COMPLIMENTARY : COMPLIMENTARY -OUTGOING FAX COMPLIMENTARY : COMPLIMENTARY",
            "deposit": "NO DEPOSIT REQUIRED",
            "extra_occupants": null,
            "guarantee": "FROM 26:10:2006 UNTIL 31:12:2050 MONDAY TUESDAYWEDNESDAY THURSDAY FRIDAY SATURDAY SUNDAYHOLD TIME: 19:00GUESTS ARRIVING AFTER 19:00 (LOCAL TIME) MUST PROVIDE A GUARANTEE.ACCEPTED FORM OF GUARANTEE - 26:10:2006 - 31:12:2050 CREDIT CARDCREDIT CARD ACCEPTED FOR GUARANTEE AX - CA - DC - EC - IK - VINO GUARANTEE REQUIREDFROM 24:10:2006 UNTIL 31:12:2050CANCELLATION POLICIES:CANCEL BY 19:00(24 HOUR CLOCK) ON DAY OF ARRIVAL,LOCAL HOTEL TIMECANCEL 0 DAY BEFORE ARRIVALNO CANCELLATION CHARGE APPLIES PRIOR TO 19:00(LOCAL TIME) ON THE DAY OF ARRIVAL. BEYOND THAT TIME, THE FIRST NIGHT WILL BE CHARGED.",
            "meals": null,
            "policy": "CHECK-IN TIME: 12:00CHECK-IN TIME 12:00CHECK-OUT TIME: 12:00CHECK-OUT TIME 12:00NO SPECIAL CONDITIONS FOR CHILDREN.ACCEPTED FORM OF PAYMENT - 26:10:2006 - 31:12:2050 CREDIT CARDCREDIT CARD ACCEPTED FOR PAYMENT AX - CA - DC - EC - IK - VI",
            "safety": "-SAFE DEP BOX             -SMOKE DETECTOR-FIRE SAFETY              -ELEC GENERATOR-FIRE DETECTORS-EMERG LIGHTING           -SAFE",
            "stay": null,
            "tax": "CITY TAX 1.00 EUR PER PERSON PER NIGHT -FOOD & BEVERAGE TAX PER ROOM PER NIGHTINCLUSIVE - COUNTRY TAX PER ROOM PER NIGHTINCLUSIVE"
          },
          "stars": 3,
          "thumbnail": "https://static.allmyles.com/hotels/81bf3a6c/55_0.jpg"
        }
      }

.. _Hotel_Room_Details:

--------------
 Room Details
--------------

Request
=======

.. http:get:: /hotels/:hotel_id/rooms/:room_id

    **hotel_id** is the ID of the :ref:`hotel-result` the room belongs to,
    **room_id** is the ID of the :ref:`Room` to get the details of.

Response Body
=============

    :JSON Parameters:
        - **hotel_room_details** (:ref:`HotelRoomDetailsContainer`) -- root
          container

.. _HotelRoomDetailsContainer:

HotelRoomDetails
----------------

    :JSON Parameters:
        - **rules** (*Rules*) -- Contains an associative array, mapping each
          rule type listed below to the relevant text, or a relevant boolean
          value. List of keys: 'cancellation', 'notes', 'needs_guarantee',
          'needs_deposit'
        - **price** (*RoomPrice*) --

          - **amount** (*Float*) --
          - **includes** (*String \[ \]*) -- Contains what services or extras
            are included in the price.

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

      {
        "hotel_room_details": {
          "price": {
            "amount": "12887.08",
            "includes": [
              "Extra Adult",
              "Value Added Tax"
            ]
          },
          "rules": {
            "cancellation": "CANCEL LATEST BY 01-MAR-15 12PM TO AVOID PENALTY OF 36.00<br>",
            "needs_deposit": false,
            "needs_guarantee": true,
            "notes": "NON SMOKING DOUBLE EN SUITE<br>MAX OCCUPANCY 2 ADULTS<br>1 DOUBLE BED<br> BAR FLEXIBLE RATE<br>GUARANTEE IS MANDATORY,AX,CA,MC,TG,VI<br>A DEPOSIT IS NOT REQUIRED.<br>Minimum Duration, 1, Days<br>Maximum Duration, 28, Days<br>"
          }
        }
      }

.. _Hotel_Booking:

---------
 Booking
---------

Request
=======

.. http:post:: /books

    :JSON Parameters:
        - **bookBasket** (*String \[ \]*) -- an array containing only the
          booking ID of the :ref:`Room` to book
        - **billingInfo** (:ref:`Contact`) -- billing info for the booking
        - **contactInfo** (:ref:`Contact`) -- contact info for the booking
        - **persons** (:ref:`Person` *\[ \]*) -- the list of occupants

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

.. _HotelPerson:

Person
------

    :JSON Parameters:
        - **birthDate** (*String*) -- format is ``YYYY-MM-DD``
        - **email** (*String*)
        - **namePrefix** (*String*) -- one of ``Mr``, ``Ms``, or ``Mrs``
        - **firstName** (*String*)
        - **lastName** (*String*)
        - **gender** (*String*) -- one of ``MALE`` or ``FEMALE``

Response Body
=============

    :JSON Parameters:
        - **confirmation** (*String*) -- the ID of the booking, this is what
          the occupant can use at the hotel to refer to his booking
        - **pnr** (*String*) -- the PNR locator of the record in which the
          booking was made

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "bookBasket": ["1_0/2_0"],
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
              "birthDate": "1974-04-03",
              "email": "aaa@gmail.com",
              "firstName": "Janos",
              "gender": "MALE",
              "lastName": "Kovacs",
              "namePrefix": "Mr"
            }
          ]
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "confirmation": "305863919",
          "pnr": "6JT3ZB"
        }
